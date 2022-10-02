class_name StableHordeClient
extends HTTPRequest

signal images_generated(completed_payload)
signal request_failed(error_msg)
signal request_warning(warning_msg)
signal image_processing(stats)

enum SamplerMethods {
	k_lms = 0
	k_heun
	k_euler
	k_euler_a
	k_dpm_2
	k_dpm_2_a
	DDIM
	PLMS
}

enum OngoingRequestOperations {
	CHECK
	GET
	CANCEL
}

enum States {
	READY
	WORKING
	CANCELLING
}

export(String) var prompt = "A horde of cute blue robots with gears on their head"
# The API key you've generated from https://stablehorde.net/register
# You can pass either your own key (make sure you encrypt your app)
# Or ask each player to register on their own
# You can also pass the 0000000000 Anonymous key, but it has the lowest priority
export(String) var api_key := '0000000000'
# How many images following the same prompt to do
export(int) var amount := 1
# The exact size of the image to generate. If you put too high, you might have to wait longer
# For a worker which can generate it
# Try not to go lower than 512 on both sizes, as 512 is what the model has been trained on.
export(int,64,1024,64) var width := 512
export(int,64,1024,64) var height := 512
# The steps correspond directly to the time it takes to get back your image.
# Generally there's usually no reason to go above 50 unless you know what you're doing.
export(int,1,200) var steps := 50
# Advanced: The sampler used to generate. Provides slight variations on the same prompt.
export(String, "k_lms", "k_heun", "k_euler", "k_euler_a", "k_dpm_2", "k_dpm_2_a", "DDIM", "PLMS") var sampler_name := "k_lms"
# How closely to follow the prompt given
export(float,-40,30,0.5) var cfg_scale := 7.5
# The unique seed for the prompt. If you pass a value in the seed and keep all the values the same
# The same image will always be generated.
export(String) var gen_seed := ''
# If set to True, will mark this generation as NSFW and only workers which accept NSFW requests
# Will fulfill it
export(bool) var nsfw := false
# Only active is nsfw == false
# Will request workers to censor accidentally generated NSFW images. 
# If set to false, and a sfw request accidently generates nsfw content, the worker
# will automatically set it to a black image.
export(bool) var censor_nsfw := true


var all_image_textures := []
var latest_image_textures := []
# The open request UUID to track its status
var async_request_id : String
# We store the params sent to the current generation, then pass them to the AIImageTexture to remember them
# They are replaced every time a new generation begins
var imgen_params : Dictionary
# When set to true, we will abort the current generation and try to retrieve whatever images we can
var state : int = States.READY
var request_start_time : float # We use that to get the accurate amount of time the request took

func _ready():
	# warning-ignore:return_value_discarded
	connect("request_completed",self,"_on_request_completed")

func generate(replacement_prompt := '', replacement_params := {}) -> void:
	if state != States.READY:
		push_error("Client currently working. Cannot do more than 1 request at a time with the same Stable Horde Client.")
		return
	request_start_time = OS.get_ticks_msec()
	state = States.WORKING
	latest_image_textures.clear()
	imgen_params = {
		"n": amount,
		"width": width,
		"height": height,
		"steps": steps,
		"sampler_name": sampler_name,
		"cfg_scale": cfg_scale,
		"seed": gen_seed,
		# You can put extra SD webui params here if you wish
	}
	for param in replacement_params:
		imgen_params[param] = replacement_params[param]
	var submit_dict = {
		"prompt": prompt,
		"params": imgen_params,
		"nsfw": nsfw,
		"censor_nsfw": censor_nsfw,
	}
	if replacement_prompt != '':
		submit_dict['prompt'] = replacement_prompt
	var body = to_json(submit_dict)
	var headers = ["Content-Type: application/json", "apikey: " + api_key]
	var error = request("https://stablehorde.net/api/v2/generate/async", headers, false, HTTPClient.METHOD_POST, body)
	if error != OK:
		var error_msg := "Something went wrong when initiating the stable horde request"
		push_error(error_msg)
		emit_signal("request_failed",error_msg)

# warning-ignore:unused_argument
func _on_request_completed(_result, response_code, _headers, body):
	if response_code == 0:
			var error_msg := "Stable Horde address cannot be resolved!"
			push_error(error_msg)
			emit_signal("request_failed",error_msg)
			return
	if response_code == 404:
			var error_msg := "Bad URL. Please contact the developer of this addon"
			push_error(error_msg)
			emit_signal("request_failed",error_msg)
			return
	var json_ret = parse_json(body.get_string_from_utf8())
	var json_error = json_ret
	if typeof(json_ret) == TYPE_DICTIONARY and json_ret.has('message'):
		json_error = str(json_ret['message'])
	if typeof(json_ret) == TYPE_NIL:
		json_error = 'Connection Lost'
	if not response_code in [200, 202] or typeof(json_ret) == TYPE_STRING:
			var error_msg : String = "Error received from the Stable Horde: " +  json_error
			push_error(error_msg)
			emit_signal("request_failed",error_msg)
			return
	if json_ret.has('message'):
		emit_signal("request_warning", json_ret['message'])
	if typeof(json_ret) == TYPE_ARRAY:
		_extract_images(json_ret)
		return
	if 'generations' in json_ret:
		_extract_images(json_ret['generations'])
		return
	if state ==States.CANCELLING:
		check_request_process(OngoingRequestOperations.CANCEL)
	if 'id' in json_ret:
		async_request_id = json_ret['id']
		check_request_process(OngoingRequestOperations.CHECK)
	if 'done' in json_ret:
		var operation = OngoingRequestOperations.CHECK
		if json_ret['done']:
			operation = OngoingRequestOperations.GET
		elif state == States.WORKING:
			json_ret["elapsed_time"] = OS.get_ticks_msec() - request_start_time
			emit_signal("image_processing", json_ret)
		check_request_process(operation)


func check_request_process(operation := OngoingRequestOperations.CHECK) -> void:
	# We do one check request per second
	yield(get_tree().create_timer(1), "timeout")
	var url = "https://stablehorde.net/api/v2/generate/check/" + async_request_id
	var method = HTTPClient.METHOD_GET
	if operation == OngoingRequestOperations.GET:
		url = "https://stablehorde.net/api/v2/generate/status/" + async_request_id
	elif operation == OngoingRequestOperations.CANCEL:
		url = "https://stablehorde.net/api/v2/generate/status/" + async_request_id
		method = HTTPClient.METHOD_DELETE
	var error = request(url, [], false, method)
	if state == States.WORKING and error != OK:
		var error_msg := "Something went wrong when checking the status of Stable Horde Request: " + async_request_id
		push_error(error_msg)
		emit_signal("request_failed",error_msg)
	elif state == States.CANCELLING and not error in [ERR_BUSY, OK] :
		var error_msg := "Something went wrong when cancelling the Stable Horde Request: " + async_request_id
		push_error(error_msg)
		emit_signal("request_failed",error_msg)


func _extract_images(generations_array: Array) -> void:
	for img_dict in generations_array:
		var b64img = img_dict["img"]
		var base64_bytes = Marshalls.base64_to_raw(b64img)
		var image = Image.new()
		var error = image.load_webp_from_buffer(base64_bytes)
		if error != OK:
			var error_msg := "Couldn't load the image."
			push_error(error_msg)
			emit_signal("request_failed",error_msg)
			return
		var texture = AIImageTexture.new(
			prompt,
			imgen_params,
			img_dict["seed"],
			img_dict["worker_id"],
			img_dict["worker_name"],
			image)
		texture.create_from_image(image)
		latest_image_textures.append(texture)
		all_image_textures.append(texture)
	var completed_payload = {
		"image_textures": latest_image_textures,
		"elapsed_time": OS.get_ticks_msec() - request_start_time
	}
	request_start_time = 0
	emit_signal("images_generated",completed_payload)
	state = States.READY


func get_sampler_method_id() -> String:
	return(SamplerMethods[sampler_name])


func is_ready() -> bool:
	return(get_http_client_status() == HTTPClient.STATUS_DISCONNECTED)


func cancel_request() -> void:
	print_debug("Cancelling...")
	state = States.CANCELLING
