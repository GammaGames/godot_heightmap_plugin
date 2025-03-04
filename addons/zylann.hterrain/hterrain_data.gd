tool
extends Resource

const Grid = preload("util/grid.gd")
const Util = preload("util/util.gd")
const Errors = preload("util/errors.gd")

# TODO Rename "CHANNEL" to "MAP", makes more sense and less confusing with RGBA channels
const CHANNEL_HEIGHT = 0
const CHANNEL_NORMAL = 1
const CHANNEL_SPLAT = 2
const CHANNEL_COLOR = 3
const CHANNEL_DETAIL = 4
const CHANNEL_GLOBAL_ALBEDO = 5
const CHANNEL_COUNT = 6

const MAX_RESOLUTION = 4096 + 1
const MIN_RESOLUTION = 64 + 1 # must be higher than largest minimum chunk size
const DEFAULT_RESOLUTION = 512
const VERTICAL_BOUNDS_CHUNK_SIZE = 16
# TODO Have vertical bounds chunk size to emphasise the fact it's independent
# TODO Have undo chunk size to emphasise the fact it's independent

const META_EXTENSION = "hterrain"
const META_FILENAME = "data.hterrain"
const META_VERSION = "0.11"


signal resolution_changed
signal region_changed(x, y, w, h, channel)
# TODO Instead of message, send a state enum and a var (for translation and code semantic)
signal progress_notified(info) # { "progress": real, "message": string, "finished": bool }
signal map_added(type, index)
signal map_removed(type, index)
signal map_changed(type, index)


class VerticalBounds:
	var minv = 0
	var maxv = 0


# A map is a texture covering the terrain.
# The usage of a map depends on its type (heightmap, normalmap, splatmap...).
class Map:
	var texture
	# Reference used in case we need the data CPU-side
	var image
	# ID used for saving, because when adding/removing maps,
	# we shouldn't rename texture files just because the indexes change.
	# This is mostly for internal keeping. The API still uses indexes that may shift if your remove a map.
	var id = -1
	# Should be set to true if the map has unsaved modifications.
	var modified = true

	func _init(p_id):
		id = p_id


var _resolution = 0

# There can be multiple maps of the same type, though most of them are single
# [map_type][instance_index] => map
var _maps = [[]]

# TODO Store vertical bounds in a RGF image? Where R is min amd G is max
var _chunked_vertical_bounds = []
var _chunked_vertical_bounds_size_x = 0
var _chunked_vertical_bounds_size_y = 0
var _locked = false
var _progress_complete = true

var _edit_disable_apply_undo = false


func _init():
	# Initialize default maps
	_set_default_maps()


func _set_default_maps():
	_maps.resize(CHANNEL_COUNT)
	for c in range(CHANNEL_COUNT):
		var maps = []
		var n = _get_channel_default_count(c)
		for i in range(n):
			maps.append(Map.new(i))
		_maps[c] = maps


func _edit_load_default():
	print("Loading default data")
	_set_default_maps()
	resize(DEFAULT_RESOLUTION)


# Don't use the data if this getter returns false
func is_locked():
	return _locked


func get_resolution():
	return _resolution


# @obsolete
func set_resolution(p_res):
	print("`HTerrainData.set_resolution()` is obsolete, use `resize()` instead")
	resize(p_res)


# @obsolete
func set_resolution2(p_res, update_normals):
	print("`HTerrainData.set_resolution2()` is obsolete, use `resize()` instead")
	resize(p_res, true, Vector2(-1, -1))


# Resizes all maps of the terrain. This may take some time to complete.
# Note that no upload to GPU is done, you have to do it once you're done with all changes,
# by calling `notify_region_change` or `notify_full_change`.
# p_res: new resolution. Must be a power of two + 1.
# stretch: if true, the terrain will be stretched in X and Z axes. If false, it will be cropped or expanded.
# anchor: if stretch is false, decides which side or corner to crop/expand the terrain from.
#
# There is an off-by-one in the data, so for example a map of 512x512 will actually have 513x513 cells.
# Here is why:
# If we had an even amount of cells, it would produce this situation when making LOD chunks:
#
#   x---x---x---x      x---x---x---x
#   |   |   |   |      |       |
#   x---x---x---x      x   x   x   x
#   |   |   |   |      |       |
#   x---x---x---x      x---x---x---x
#   |   |   |   |      |       |
#   x---x---x---x      x   x   x   x
#
#       LOD 0              LOD 1
#
# We would be forced to ignore the last cells because they would produce an irregular chunk.
# We need an off-by-one because quads making up chunks SHARE their consecutive vertices.
# One quad needs at least 2x2 cells to exist. Two quads of the heightmap share an edge, which needs a total of 3x3 cells, not 4x4.
# One chunk has 16x16 quads, so it needs 17x17 cells, not 16, where the last cell is shared with the next chunk.
# As a result, a map of 4x4 chunks needs 65x65 cells, not 64x64.
func resize(p_res, stretch=true, anchor=Vector2(-1, -1)):
	assert(typeof(p_res) == TYPE_INT)
	assert(typeof(stretch) == TYPE_BOOL)
	assert(typeof(anchor) == TYPE_VECTOR2)

	print("HeightMapData::set_resolution ", p_res)

	if p_res == get_resolution():
		return

	p_res = Util.clamp_int(p_res, MIN_RESOLUTION, MAX_RESOLUTION)

	# Power of two is important for LOD.
	# Also, grid data is off by one,
	# because for an even number of quads you need an odd number of vertices.
	# To prevent size from increasing at every deserialization, remove 1 before applying power of two.
	p_res = Util.next_power_of_two(p_res - 1) + 1

	_resolution = p_res;

	for channel in range(CHANNEL_COUNT):
		var maps = _maps[channel]

		for index in len(maps):
			print("Resizing ", _get_map_debug_name(channel, index), "...")

			var map = maps[index]
			var im = map.image

			if im == null:
				im = Image.new()
				im.create(_resolution, _resolution, false, get_channel_format(channel))

				var fill_color = _get_channel_default_fill(channel)
				if fill_color != null:
					im.fill(fill_color)

				map.image = im

			else:
				if stretch and channel == CHANNEL_NORMAL:
					im.create(_resolution, _resolution, false, get_channel_format(channel))
				else:
					if stretch:
						im.resize(_resolution, _resolution)
					else:
						map.image = Util.get_cropped_image( \
							im, _resolution, _resolution, _get_channel_default_fill(channel), anchor)

			map.modified = true

	_update_all_vertical_bounds()

	emit_signal("resolution_changed")


static func _get_clamped(im, x, y):

	if x < 0:
		x = 0
	elif x >= im.get_width():
		x = im.get_width() - 1

	if y < 0:
		y = 0
	elif y >= im.get_height():
		y = im.get_height() - 1

	return im.get_pixel(x, y)


# Gets the height at the given cell position.
# This height is raw and doesn't account for scaling of the terrain node.
# This function is relatively slow due to locking, so don't use it to fetch large areas.
func get_height_at(x, y):

	# Height data must be loaded in RAM
	var im = get_image(CHANNEL_HEIGHT)
	assert(im != null)

	im.lock();
	var h = _get_clamped(im, x, y).r;
	im.unlock();
	return h;


# Gets the height at the given floating-point cell position.
# This height is raw and doesn't account for scaling of the terrain node.
# This function is relatively slow due to locking, so don't use it to fetch large areas
func get_interpolated_height_at(pos):

	# Height data must be loaded in RAM
	var im = get_image(CHANNEL_HEIGHT)
	assert(im != null)

	# The function takes a Vector3 for convenience so it's easier to use in 3D scripting
	var x0 = int(floor(pos.x))
	var y0 = int(floor(pos.z))

	var xf = pos.x - x0
	var yf = pos.z - y0

	im.lock()
	var h00 = _get_clamped(im, x0, y0).r
	var h10 = _get_clamped(im, x0 + 1, y0).r
	var h01 = _get_clamped(im, x0, y0 + 1).r
	var h11 = _get_clamped(im, x0 + 1, y0 + 1).r
	im.unlock()

	# Bilinear filter
	var h = lerp(lerp(h00, h10, xf), lerp(h01, h11, xf), yf)

	return h;


# Gets all heights within the given rectangle in cells.
# This height is raw and doesn't account for scaling of the terrain node.
# Data is returned as a PoolRealArray.
func get_heights_region(x0, y0, w, h):
	var im = get_image(CHANNEL_HEIGHT)
	assert(im != null)

	var min_x = Util.clamp_int(x0, 0, im.get_width())
	var min_y = Util.clamp_int(y0, 0, im.get_height())
	var max_x = Util.clamp_int(x0 + w, 0, im.get_width() + 1)
	var max_y = Util.clamp_int(y0 + h, 0, im.get_height() + 1)

	var heights = PoolRealArray()

	var area = (max_x - min_x) * (max_y - min_y)
	if area == 0:
		print("Empty heights region!")
		return heights

	heights.resize(area)

	im.lock()

	var i = 0
	for y in range(min_y, max_y):
		for x in range(min_x, max_x):
			heights[i] = im.get_pixel(x, y).r
			i += 1

	im.unlock()

	return heights


# Gets all heights.
# This height is raw and doesn't account for scaling of the terrain node.
# Data is returned as a PoolRealArray.
func get_all_heights():
	return get_heights_region(0, 0, _resolution, _resolution)


# Call this function after you end modifying a map.
# It will commit the change to the GPU so the change will take effect.
# In the editor, it will also mark the map as modified so it will be saved when needed.
# Finally, it will emit `region_changed`, which allows other systems to catch up (like physics or grass)
# p_rect: modified area.
# channel: which kind of map changed
# index: index of the map that changed
func notify_region_change(p_rect, channel, index = 0):
	assert(channel >= 0 and channel < CHANNEL_COUNT)
	
	var min_x = int(p_rect.position.x)
	var min_y = int(p_rect.position.y)
	var size_x = int(p_rect.size.x)
	var size_y = int(p_rect.size.y)
	
	if channel == CHANNEL_HEIGHT:
		assert(index == 0)
		# TODO when drawing very large patches, this might get called too often and would slow down.
		# for better user experience, we could set chunks AABBs to a very large height just while drawing,
		# and set correct AABBs as a background task once done
		_update_vertical_bounds(min_x, min_y, size_x, size_y)

	_upload_region(channel, index, min_x, min_y, size_x, size_y)
	_maps[channel][index].modified = true

	emit_signal("region_changed", min_x, min_y, size_x, size_y, channel)
	emit_signal("changed")


func notify_full_change():
	for maptype in range(CHANNEL_COUNT):

		# Ignore normals because they get updated along with heights
		if maptype == CHANNEL_NORMAL:
			continue

		var maps = _maps[maptype]

		for index in len(maps):
			notify_region_change(Rect2(0, 0, _resolution, _resolution), maptype, index)


func _edit_set_disable_apply_undo(e):
	_edit_disable_apply_undo = e


func _edit_apply_undo(undo_data):

	if _edit_disable_apply_undo:
		return

	var chunk_positions = undo_data["chunk_positions"]
	var chunk_datas = undo_data["data"]
	var channel = undo_data["channel"]
	var index = undo_data["index"]
	var chunk_size = undo_data["chunk_size"]

	# Validate input

	assert(channel >= 0 and channel < CHANNEL_COUNT)
	assert(chunk_positions.size() / 2 == chunk_datas.size())

	assert(chunk_positions.size() % 2 == 0)
	for i in range(len(chunk_positions)):
		var p = chunk_positions[i]
		assert(typeof(p) == TYPE_INT)

	for i in range(len(chunk_datas)):
		var d = chunk_datas[i]
		assert(typeof(d) == TYPE_OBJECT)
		assert(d is Image)

	var regions_changed = []

	# Apply

	for i in range(len(chunk_datas)):
		var cpos_x = chunk_positions[2 * i]
		var cpos_y = chunk_positions[2 * i + 1]

		var min_x = cpos_x * chunk_size
		var min_y = cpos_y * chunk_size
		var max_x = min_x + 1 * chunk_size
		var max_y = min_y + 1 * chunk_size

		var data = chunk_datas[i]
		assert(data != null)

		var data_rect = Rect2(0, 0, data.get_width(), data.get_height())

		var dst_image = get_image(channel, index)
		assert(dst_image != null)

		match channel:

			CHANNEL_HEIGHT, \
			CHANNEL_SPLAT, \
			CHANNEL_COLOR, \
			CHANNEL_DETAIL:
				dst_image.blit_rect(data, data_rect, Vector2(min_x, min_y))

			CHANNEL_NORMAL, \
			CHANNEL_GLOBAL_ALBEDO:
				printerr("This is a calculated channel!, no undo on this one\n")
			_:
				printerr("Wut? Unsupported undo channel\n");

		# Defer this to a second pass, otherwise it causes order-dependent artifacts on the normal map
		regions_changed.append([Rect2(min_x, min_y, max_x - min_x, max_y - min_y), channel, index])

	for args in regions_changed:
		notify_region_change(args[0], args[1], args[2])


func _upload_channel(channel, index):
	_upload_region(channel, index, 0, 0, _resolution, _resolution)


func _upload_region(channel, index, min_x, min_y, size_x, size_y):
	#print("Upload ", min_x, ", ", min_y, ", ", size_x, "x", size_y)
	#var time_before = OS.get_ticks_msec()

	var map = _maps[channel][index]

	var image = map.image
	assert(image != null)
	assert(size_x > 0 and size_y > 0)

	# TODO Actually, I think the input params should be valid in the first place...
	if min_x < 0:
		min_x = 0
	if min_y < 0:
		min_y = 0
	if min_x + size_x > image.get_width():
		size_x = image.get_width() - min_x
	if min_y + size_y > image.get_height():
		size_y = image.get_height() - min_y
	if size_x <= 0 or size_y <= 0:
		return

	var flags = 0;
	if channel == CHANNEL_NORMAL \
	or channel == CHANNEL_COLOR \
	or channel == CHANNEL_SPLAT \
	or channel == CHANNEL_HEIGHT \
	or channel == CHANNEL_GLOBAL_ALBEDO:
		flags |= Texture.FLAG_FILTER

	if channel == CHANNEL_GLOBAL_ALBEDO:
		flags |= Texture.FLAG_MIPMAPS

	var texture = map.texture

	if texture == null or not (texture is ImageTexture):

		# The texture doesn't exist yet in an editable format
		if texture != null and not (texture is ImageTexture):
			print("_upload_region was used but the texture isn't an ImageTexture. ",\
				"The map ", channel, "[", index, "] will be reuploaded entirely.")
		else:
			print("_upload_region was used but the texture is not created yet. ",\
				"The map ", channel, "[", index, "] will be uploaded entirely.")

		texture = ImageTexture.new()
		texture.create_from_image(image, flags)

		map.texture = texture

		# Need to notify because other systems may want to grab the new texture object
		emit_signal("map_changed", channel, index)

	elif texture.get_size() != image.get_size():

		print("_upload_region was used but the image size is different. ",\
			"The map ", channel, "[", index, "] will be reuploaded entirely.")

		texture.create_from_image(image, flags)

	else:
		if VisualServer.has_method("texture_set_data_partial"):
			
			VisualServer.texture_set_data_partial( \
				texture.get_rid(), image, \
				min_x, min_y, \
				size_x, size_y, \
				min_x, min_y, \
				0, 0)

		else:
			# Godot 3.0.6 and earlier...
			# It is slow.

			#               ..ooo@@@XXX%%%xx..
			#            .oo@@XXX%x%xxx..     ` .
			#          .o@XX%%xx..               ` .
			#        o@X%..                  ..ooooooo
			#      .@X%x.                 ..o@@^^   ^^@@o
			#    .ooo@@@@@@ooo..      ..o@@^          @X%
			#    o@@^^^     ^^^@@@ooo.oo@@^             %
			#   xzI    -*--      ^^^o^^        --*-     %
			#   @@@o     ooooooo^@@^o^@X^@oooooo     .X%x
			#  I@@@@@@@@@XX%%xx  ( o@o )X%x@ROMBASED@@@X%x
			#  I@@@@XX%%xx  oo@@@@X% @@X%x   ^^^@@@@@@@X%x
			#   @X%xx     o@@@@@@@X% @@XX%%x  )    ^^@X%x
			#    ^   xx o@@@@@@@@Xx  ^ @XX%%x    xxx
			#          o@@^^^ooo I^^ I^o ooo   .  x
			#          oo @^ IX      I   ^X  @^ oo
			#          IX     U  .        V     IX
			#           V     .           .     V
			#
			texture.create_from_image(image, flags)

	#print("Channel updated ", channel)

	#var time_elapsed = OS.get_ticks_msec() - time_before
	#print("Texture upload time: ", time_elapsed, "ms")


# Gets how many instances of a given map are present in the terrain data.
# A return value of 0 means there is no such map, and querying for it might cause errors.
func get_map_count(map_type):
	if map_type < len(_maps):
		return len(_maps[map_type])
	return 0


# TODO Deprecated
func _edit_add_detail_map():
	return _edit_add_map(CHANNEL_DETAIL)


# TODO Deprecated
func _edit_remove_detail_map(index):
	_edit_remove_map(CHANNEL_DETAIL, index)


func _edit_add_map(map_type):
	# TODO Check minimum and maximum instances of a given map
	print("Adding map of type ", get_channel_name(map_type))
	while map_type >= len(_maps):
		_maps.append([])
	var maps = _maps[map_type]
	var map = Map.new(_get_free_id(map_type))
	map.image = Image.new()
	map.image.create(_resolution, _resolution, false, get_channel_format(map_type))
	var index = len(maps)
	maps.append(map)
	emit_signal("map_added", map_type, index)
	return index


func _edit_remove_map(map_type, index):
	# TODO Check minimum and maximum instances of a given map
	print("Removing map ", get_channel_name(map_type), " at index ", index)
	var maps = _maps[map_type]
	maps.remove(index)
	emit_signal("map_removed", map_type, index)


func _get_free_id(map_type):
	var maps = _maps[map_type]
	var id = 0
	while _get_map_by_id(map_type, id) != null:
		id += 1
	return id


func _get_map_by_id(map_type, id):
	var maps = _maps[map_type]
	for map in maps:
		if map.id == id:
			return map
	return null


func get_image(maptype, index = 0):
	var maps = _maps[maptype]
	return maps[index].image


func _get_texture(maptype, index):
	var maps = _maps[maptype]
	return maps[index].texture


func get_texture(channel, index = 0):
	# TODO Perhaps it's not a good idea to auto-upload like that
	if _get_texture(channel, index) == null and get_image(channel) != null:
		_upload_channel(channel, index)
	return _get_texture(channel, index)


func get_aabb():
	# TODO Why subtract 1? I forgot
	return get_region_aabb(0, 0, _resolution - 1, _resolution - 1)


# Not so useful in itself, but GDScript is slow,
# so I needed it to speed up the LOD hack I had to do to take height into account
func get_point_aabb(cell_x, cell_y):
	assert(typeof(cell_x) == TYPE_INT)
	assert(typeof(cell_y) == TYPE_INT)

	var cx = cell_x / VERTICAL_BOUNDS_CHUNK_SIZE
	var cy = cell_y / VERTICAL_BOUNDS_CHUNK_SIZE

	if cx < 0:
		cx = 0
	if cy < 0:
		cy = 0
	if cx >= _chunked_vertical_bounds_size_x:
		cx = _chunked_vertical_bounds_size_x
	if cy >= _chunked_vertical_bounds_size_y:
		cy = _chunked_vertical_bounds_size_y

	var b = _chunked_vertical_bounds[cy][cx]
	return Vector2(b.minv, b.maxv)


func get_region_aabb(origin_in_cells_x, origin_in_cells_y, size_in_cells_x, size_in_cells_y):

	assert(typeof(origin_in_cells_x) == TYPE_INT)
	assert(typeof(origin_in_cells_y) == TYPE_INT)
	assert(typeof(size_in_cells_x) == TYPE_INT)
	assert(typeof(size_in_cells_y) == TYPE_INT)

	# Get info from cached vertical bounds,
	# which is a lot faster than directly fetching heights from the map.
	# It's not 100% accurate, but enough for culling use case if chunk size is decently chosen.

	var cmin_x = origin_in_cells_x / VERTICAL_BOUNDS_CHUNK_SIZE
	var cmin_y = origin_in_cells_y / VERTICAL_BOUNDS_CHUNK_SIZE

	var cmax_x = (origin_in_cells_x + size_in_cells_x - 1) / VERTICAL_BOUNDS_CHUNK_SIZE + 1
	var cmax_y = (origin_in_cells_y + size_in_cells_y - 1) / VERTICAL_BOUNDS_CHUNK_SIZE + 1

	if cmin_x < 0:
		cmin_x = 0
	if cmin_y < 0:
		cmin_y = 0
	if cmax_x >= _chunked_vertical_bounds_size_x:
		cmax_x = _chunked_vertical_bounds_size_x
	if cmax_y >= _chunked_vertical_bounds_size_y:
		cmax_y = _chunked_vertical_bounds_size_y

	var min_height = 0
	if cmin_x < _chunked_vertical_bounds_size_x and cmin_y < _chunked_vertical_bounds_size_y:
		min_height = _chunked_vertical_bounds[cmin_y][cmin_x].minv
	var max_height = min_height

	for y in range(cmin_y, cmax_y):
		for x in range(cmin_x, cmax_x):

			var b = _chunked_vertical_bounds[y][x]

			if b.minv < min_height:
				min_height = b.minv

			if b.maxv > max_height:
				max_height = b.maxv

	var aabb = AABB()
	aabb.position = Vector3(origin_in_cells_x, min_height, origin_in_cells_y)
	aabb.size = Vector3(size_in_cells_x, max_height - min_height, size_in_cells_y)

	return aabb


func _update_all_vertical_bounds():
	var csize_x = _resolution / VERTICAL_BOUNDS_CHUNK_SIZE
	var csize_y = _resolution / VERTICAL_BOUNDS_CHUNK_SIZE
	print("Updating all vertical bounds... (", csize_x , "x", csize_y, " chunks)")
	# TODO Could set `preserve_data` to true, but would require callback to construct new cells
	Grid.resize_grid(_chunked_vertical_bounds, csize_x, csize_y)
	_chunked_vertical_bounds_size_x = csize_x
	_chunked_vertical_bounds_size_y = csize_y

	_update_vertical_bounds(0, 0, _resolution - 1, _resolution - 1)


func _update_vertical_bounds(origin_in_cells_x, origin_in_cells_y, size_in_cells_x, size_in_cells_y):

	var cmin_x = origin_in_cells_x / VERTICAL_BOUNDS_CHUNK_SIZE
	var cmin_y = origin_in_cells_y / VERTICAL_BOUNDS_CHUNK_SIZE

	var cmax_x = (origin_in_cells_x + size_in_cells_x - 1) / VERTICAL_BOUNDS_CHUNK_SIZE + 1
	var cmax_y = (origin_in_cells_y + size_in_cells_y - 1) / VERTICAL_BOUNDS_CHUNK_SIZE + 1

	cmin_x = Util.clamp_int(cmin_x, 0, _chunked_vertical_bounds_size_x - 1)
	cmin_y = Util.clamp_int(cmin_y, 0, _chunked_vertical_bounds_size_y - 1)
	cmax_x = Util.clamp_int(cmax_x, 0, _chunked_vertical_bounds_size_x)
	cmax_y = Util.clamp_int(cmax_y, 0, _chunked_vertical_bounds_size_y)

	# Note: chunks in _chunked_vertical_bounds share their edge cells and have an actual size of chunk size + 1.
	var chunk_size_x = VERTICAL_BOUNDS_CHUNK_SIZE + 1
	var chunk_size_y = VERTICAL_BOUNDS_CHUNK_SIZE + 1

	for y in range(cmin_y, cmax_y):
		var pmin_y = y * VERTICAL_BOUNDS_CHUNK_SIZE

		for x in range(cmin_x, cmax_x):

			var b = _chunked_vertical_bounds[y][x]
			if b == null:
				b = VerticalBounds.new()
				_chunked_vertical_bounds[y][x] = b

			var pmin_x = x * VERTICAL_BOUNDS_CHUNK_SIZE
			_compute_vertical_bounds_at(pmin_x, pmin_y, chunk_size_x, chunk_size_y, b);


func _compute_vertical_bounds_at(origin_x, origin_y, size_x, size_y, out_b):

	var heights = get_image(CHANNEL_HEIGHT)
	assert(heights != null)

	var min_x = origin_x
	var min_y = origin_y
	var max_x = origin_x + size_x
	var max_y = origin_y + size_y

	heights.lock();

	var min_height = heights.get_pixel(min_x, min_y).r
	var max_height = min_height

	for y in range(min_y, max_y):
		for x in range(min_x, max_x):

			var h = heights.get_pixel(x, y).r

			if h < min_height:
				min_height = h
			elif h > max_height:
				max_height = h

	heights.unlock()

	out_b.minv = min_height
	out_b.maxv = max_height


func _notify_progress(message, progress, finished = false):
	_progress_complete = finished
	print("[", int(100.0 * progress), "%] ", message)
	emit_signal("progress_notified", {
		"message": message,
		"progress": progress,
		"finished": finished
	})


func _notify_progress_complete():
	_notify_progress("Done", 1.0, true)


func save_data(data_dir):
	if not _is_any_map_modified():
		print("Terrain data has no modifications to save")
		return

	_locked = true

	_save_metadata(data_dir.plus_file(META_FILENAME))

	_notify_progress("Saving terrain data...", 0.0)

	var map_count = _get_total_map_count()

	var pi = 0
	for channel in range(CHANNEL_COUNT):
		var maps = _maps[channel]

		for index in range(len(maps)):

			var map = _maps[channel][index]
			if not map.modified:
				print("Skipping non-modified ", _get_map_debug_name(channel, index))
				continue

			var p = 0.1 + 0.9 * float(pi) / float(map_count)
			_notify_progress(str("Saving map ", _get_map_debug_name(channel, index), \
				" as ", _get_map_filename(channel, index), "..."), p)

			_save_channel(data_dir, channel, index)

			map.modified = false
			pi += 1

	# TODO In editor, trigger reimport on generated assets

	_locked = false
	_notify_progress_complete()


func _is_any_map_modified():
	for maplist in _maps:
		for map in maplist:
			if map.modified:
				return true
	return false


func _get_total_map_count():
	var s = 0
	for maps in _maps:
		s += len(maps)
	return s


func _load_metadata(path):
	var f = File.new()
	var err = f.open(path, File.READ)
	assert(err == OK)
	var text = f.get_as_text()
	f.close()
	var res = JSON.parse(text)
	assert(res.error == OK)
	_deserialize_metadata(res.result)


func _save_metadata(path):
	var f = File.new()
	var d = _serialize_metadata()
	var text = JSON.print(d, "\t", true)
	var err = f.open(path, File.WRITE)
	assert(err == OK)
	f.store_string(text)
	f.close()


func _serialize_metadata():
	var data = []
	data.resize(len(_maps))

	for i in range(len(_maps)):
		var maps = _maps[i]
		var maps_data = []

		for j in range(len(maps)):
			var map = maps[j]
			maps_data.append({ "id": map.id })

		data[i] = maps_data

	return {
		"version": META_VERSION,
		"maps": data
	}


# Parse metadata that we'll then use to load the actual terrain
# (How many maps, which files to load etc...)
func _deserialize_metadata(dict):

	if not dict.has("version"):
		printerr("Terrain metadata has no version")
		return false

	if dict.version != META_VERSION:
		printerr("Terrain metadata version mismatch. Got ", dict.version, ", expected ", META_VERSION)
		return false

	var data = dict["maps"]
	_maps.resize(len(data))

	for i in range(len(data)):
		var maps = _maps[i]

		if maps == null:
			maps = []
			_maps[i] = maps

		var maps_data = data[i]
		if len(maps) != len(maps_data):
			maps.resize(len(maps_data))

		for j in range(len(maps)):
			var map = maps[j]
			var id = maps_data[j].id
			if map == null:
				map = Map.new(id)
				maps[j] = map
			else:
				map.id = id

	return true


func load_data(dir_path):
	_locked = true

	_load_metadata(dir_path.plus_file(META_FILENAME))

	_notify_progress("Loading terrain data...", 0.0)

	var channel_instance_sum = _get_total_map_count()
	var pi = 0

	# Note: if we loaded all maps at once before uploading them to VRAM,
	# it would take a lot more RAM than if we load them one by one
	for map_type in range(len(_maps)):
		var maps = _maps[map_type]

		for index in range(len(maps)):

			var p = 0.1 + 0.6 * float(pi) / float(channel_instance_sum)
			_notify_progress(str("Loading map ", _get_map_debug_name(map_type, index), \
				" from ", _get_map_filename(map_type, index), "..."), p)

			_load_channel(dir_path, map_type, index)

			# A map that was just loaded is considered not modified yet
			_maps[map_type][index].modified = false

			pi += 1

	_notify_progress("Calculating vertical bounds...", 0.8)
	_update_all_vertical_bounds()

	_notify_progress("Notify resolution change...", 0.9)

	_locked = false
	emit_signal("resolution_changed")

	_notify_progress_complete()


func get_data_dir():
	# The HTerrainData resource represents the metadata and entry point for Godot.
	# It should be placed within a folder dedicated for terrain storage.
	# Other heavy data such as maps are stored next to that file.
	return resource_path.get_base_dir()


func _save_channel(dir_path, channel, index):
	var map = _maps[channel][index]
	var im = map.image
	if im == null:
		var tex = map.texture
		if tex != null:
			print("Image not found for channel ", channel, ", downloading from VRAM")
			im = tex.get_data()
		else:
			print("No data in channel ", channel, "[", index, "]")
			# This data doesn't have such channel
			return true

	var dir = Directory.new()
	if not dir.dir_exists(dir_path):
		dir.make_dir(dir_path)

	var fpath = dir_path.plus_file(_get_map_filename(channel, index))

	if _channel_can_be_saved_as_png(channel):
		fpath += ".png"
		im.save_png(fpath)
		_try_write_default_import_options(fpath, channel)

	else:
		fpath += ".res"
		var err = ResourceSaver.save(fpath, im)
		if err != OK:
			printerr("Could not save ", fpath, ", error ", Errors.get_message(err))
			return false
		_try_delete_0_8_0_heightmap(fpath.get_basename())

	return true


static func _try_write_default_import_options(fpath, channel):
	var imp_fpath = fpath + ".import"
	var f = File.new()
	if f.file_exists(imp_fpath):
		# Already exists
		return

	var defaults = {
		"remap": {
			"importer": "texture",
			"type": "StreamTexture"
		},
		"deps": {
			"source_file": fpath
		},
		"params": {
			# Don't compress. It ruins quality and makes the editor choke on big textures.
			# I would have used ImageTexture.COMPRESS_LOSSLESS,
			# but apparently what is saved in the .import file does not match,
			# and rather corresponds TO THE UI IN THE IMPORT DOCK :facepalm:
			"compress/mode": 0,
			"compress/hdr_mode": 0,
			"compress/normal_map": 0,
			"flags/mipmaps": false,
			"flags/filter": true,
			# No need for this, the meaning of alpha is never transparency
			"process/fix_alpha_border": false,
			# Don't try to be smart.
			# This can actually overwrite the settings with defaults...
			# https://github.com/godotengine/godot/issues/24220
			"detect_3d": false
		}
	}

	var err = f.open(imp_fpath, File.WRITE)
	if err != OK:
		printerr("Could not open `", imp_fpath, "` for write, error ", Errors.get_message(err))
		return

	for section in defaults:
		f.store_line(str("[", section, "]"))
		f.store_line("")
		var params = defaults[section]
		for key in params:
			var v = params[key]
			var sv
			match typeof(v):
				TYPE_STRING:
					sv = str('"', v.replace('"', '\"'), '"')
				TYPE_BOOL:
					sv = "true" if v else "false"
				_:
					sv = str(v)
			f.store_line(str(key, "=", sv))
		f.store_line("")

	f.close()


func _load_channel(dir, channel, index):
	var fpath = dir.plus_file(_get_map_filename(channel, index))

	# Maps must be configured before being loaded
	var map = _maps[channel][index]
	# while len(_maps) <= channel:
	# 	_maps.append([])
	# while len(_maps[channel]) <= index:
	# 	_maps[channel].append(null)
	# var map = _maps[channel][index]
	# if map == null:
	# 	map = Map.new()
	# 	_maps[channel][index] = map

	if _channel_can_be_saved_as_png(channel):
		fpath += ".png"
		# In this particular case, we can use Godot ResourceLoader directly, if the texture got imported.

		if Engine.editor_hint:
			# But in the editor we want textures to be editable,
			# so we have to automatically load the data also in RAM
			if map.image == null:
				map.image = Image.new()
			map.image.load(fpath)

		var tex = load(fpath)
		map.texture = tex

	else:
		var im = _try_load_0_8_0_heightmap(fpath, channel, map.image)
		if typeof(im) == TYPE_BOOL:
			return false
		if im == null:
			fpath += ".res"
			im = load(fpath)
		if im == null:
			printerr("Could not load ", fpath)
			return false

		_resolution = im.get_width()

		map.image = im
		_upload_channel(channel, index)

	return true


# Legacy
# TODO Drop after a few versions
static func _try_load_0_8_0_heightmap(fpath, channel, existing_image):
	fpath += ".bin"
	var f = File.new()
	if not f.file_exists(fpath):
		return null
	var err = f.open(fpath, File.READ)
	if err != OK:
		printerr("Could not open ", fpath, " for reading, error ", Errors.get_message(err))
		return false

	var width = f.get_32()
	var height = f.get_32()
	var pixel_size = f.get_32()
	var data_size = width * height * pixel_size
	var data = f.get_buffer(data_size)
	if data.size() != data_size:
		printerr("Unexpected end of buffer, expected size ", data_size, ", got ", data.size())
		return false

	var im = existing_image
	if im == null:
		im = Image.new()
	im.create_from_data(width, height, false, get_channel_format(channel), data)
	return im


static func _try_delete_0_8_0_heightmap(fpath):
	fpath += ".bin"
	var d = Directory.new()
	if d.file_exists(fpath):
		var err = d.remove(fpath)
		if err != OK:
			printerr("Could not erase file ", fpath, ", error ", Errors.get_message(err))


# Imports images into the terrain data by converting them to the internal format.
# It is possible to omit some of them, in which case those already setup will be used.
# This function is quite permissive, and will only fail if there is really no way to import.
# It may involve cropping, so preliminary checks should be done to inform the user.
#
# TODO Plan is to make this function threaded, in case import takes too long.
# So anything that could mess with the main thread should be avoided.
# Eventually, it would be temporarily removed from the terrain node to work in isolation during import.
func _edit_import_maps(input):
	assert(typeof(input) == TYPE_DICTIONARY)

	if input.has(CHANNEL_HEIGHT):
		var params = input[CHANNEL_HEIGHT]
		if not _import_heightmap(params.path, params.min_height, params.max_height):
			return false

	var maptypes = [CHANNEL_COLOR, CHANNEL_SPLAT]

	for map_type in maptypes:
		if input.has(map_type):
			var params = input[map_type]
			if not _import_map(map_type, params.path):
				return false

	return true


# Provided an arbitrary width and height, returns the closest size the terrain actually supports
static func get_adjusted_map_size(width, height):
	var width_po2 = Util.next_power_of_two(width - 1) + 1
	var height_po2 = Util.next_power_of_two(height - 1) + 1
	var size_po2 = Util.min_int(width_po2, height_po2)
	size_po2 = Util.clamp_int(size_po2, MIN_RESOLUTION, MAX_RESOLUTION)
	return size_po2


func _import_heightmap(fpath, min_y, max_y):
	var ext = fpath.get_extension().to_lower()

	if ext == "png":
		# Godot can only load 8-bit PNG,
		# so we have to bring it back to float in the wanted range

		var src_image = Image.new()
		var err = src_image.load(fpath)
		if err != OK:
			return false

		var res = get_adjusted_map_size(src_image.get_width(), src_image.get_height())
		if res != src_image.get_width():
			src_image.crop(res, res)

		_locked = true

		print("Resizing terrain to ", res, "x", res, "...")
		resize(src_image.get_width(), true, Vector2())

		var im = get_image(CHANNEL_HEIGHT)
		assert(im != null)

		var hrange = max_y - min_y

		var width = Util.min_int(im.get_width(), src_image.get_width())
		var height = Util.min_int(im.get_height(), src_image.get_height())

		print("Converting to internal format...", 0.2)

		im.lock()
		src_image.lock()

		# Convert to internal format (from RGBA8 to RH16) with range scaling
		for y in range(0, width):
			for x in range(0, height):
				var gs = src_image.get_pixel(x, y).r
				var h = min_y + hrange * gs
				im.set_pixel(x, y, Color(h, 0, 0))

		src_image.unlock()
		im.unlock()

	elif ext == "raw":
		# RAW files don't contain size, so we have to deduce it from 16-bit size.
		# We also need to bring it back to float in the wanted range.

		var f = File.new()
		var err = f.open(fpath, File.READ)
		if err != OK:
			return false

		var file_len = f.get_len()
		var file_res = Util.integer_square_root(file_len / 2)
		if file_res == -1:
			# Can't deduce size
			return false

		var res = get_adjusted_map_size(file_res, file_res)

		var width = res
		var height = res

		_locked = true

		print("Resizing terrain to ", width, "x", height, "...")
		resize(res, true, Vector2())

		var im = get_image(CHANNEL_HEIGHT)
		assert(im != null)

		var hrange = max_y - min_y

		print("Converting to internal format...")

		im.lock()

		var rw = Util.min_int(res, file_res)
		var rh = Util.min_int(res, file_res)

		# Convert to internal format (from bytes to RH16)
		var h = 0.0
		for y in range(0, rh):
			for x in range(0, rw):
				var gs = float(f.get_16()) / 65536.0
				h = min_y + hrange * float(gs)
				im.set_pixel(x, y, Color(h, 0, 0))
			# Skip next pixels if the file is bigger than the accepted resolution
			for x in range(rw, file_res):
				f.get_16()

		im.unlock()

	else:
		# File extension not recognized
		return false

	_locked = false

	print("Notify region change...")
	notify_region_change(Rect2(0, 0, get_resolution(), get_resolution()), CHANNEL_HEIGHT)

	return true


func _import_map(map_type, path):
	# Heightmap requires special treatment
	assert(map_type != CHANNEL_HEIGHT)

	var im = Image.new()
	var err = im.load(path)
	if err != OK:
		return false

	var res = get_resolution()
	if im.get_width() != res or im.get_height() != res:
		im.crop(res, res)

	if im.get_format() != get_channel_format(map_type):
		im.convert(get_channel_format(map_type))

	var map = _maps[map_type][0]
	map.image = im

	notify_region_change(Rect2(0, 0, im.get_width(), im.get_height()), map_type)
	return true


# TODO Workaround for https://github.com/Zylann/godot_heightmap_plugin/issues/101
func _dummy_function():
	pass


static func _encode_normal(n):
	return Color(0.5 * (n.x + 1.0), 0.5 * (n.z + 1.0), 0.5 * (n.y + 1.0), 1.0)


static func get_channel_format(channel):
	match channel:
		CHANNEL_HEIGHT:
			return Image.FORMAT_RH
		CHANNEL_NORMAL:
			return Image.FORMAT_RGB8
		CHANNEL_SPLAT:
			return Image.FORMAT_RGBA8
		CHANNEL_COLOR:
			return Image.FORMAT_RGBA8
		CHANNEL_DETAIL:
			return Image.FORMAT_L8
		CHANNEL_GLOBAL_ALBEDO:
			return Image.FORMAT_RGB8

	printerr("Unrecognized channel\n")
	return Image.FORMAT_MAX


# Note: PNG supports 16-bit channels, unfortunately Godot doesn't
static func _channel_can_be_saved_as_png(channel):
	if channel == CHANNEL_HEIGHT:
		return false
	return true


static func get_channel_name(c):
	var name = null
	match c:
		CHANNEL_COLOR:
			name = "color"
		CHANNEL_SPLAT:
			name = "splat"
		CHANNEL_NORMAL:
			name = "normal"
		CHANNEL_HEIGHT:
			name = "height"
		CHANNEL_DETAIL:
			name = "detail"
		CHANNEL_GLOBAL_ALBEDO:
			name = "global_albedo"
	assert(name != null)
	return name


static func _get_map_debug_name(map_type, index):
	return str(get_channel_name(map_type), "[", index, "]")


func _get_map_filename(c, index):
	var name = get_channel_name(c)
	var id = _maps[c][index].id
	if id > 0:
		name += str(id + 1)
	return name


static func _get_channel_default_fill(c):
	match c:
		CHANNEL_COLOR:
			return Color(1, 1, 1, 1)
		CHANNEL_SPLAT:
			return Color(1, 0, 0, 0)
		CHANNEL_DETAIL:
			return Color(0, 0, 0, 0)
		CHANNEL_NORMAL:
			return _encode_normal(Vector3(0, 1, 0))
		_:
			# No need to fill
			return null


static func _get_channel_default_count(c):
	if c == CHANNEL_DETAIL:
		return 0
	return 1
