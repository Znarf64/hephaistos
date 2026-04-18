package vk_compute

import "base:runtime"

import "core:fmt"
import "core:os"
@(require)
import "core:mem"
import "core:strings"
import "core:math/rand"

import stbi "vendor:stb/image"
import vk   "vendor:vulkan"

import hep "../.."

foreign import "system:libvulkan.so"

@(link_prefix = "vk")
foreign libvulkan {
	GetInstanceProcAddr :: proc(instance: vk.Instance, pName: cstring) -> vk.ProcVoidFunction ---
}

ENABLE_VALIDATION_LAYERS :: #config(ENABLE_VALIDATION_LAYERS, ODIN_DEBUG)

Vulkan_Context :: struct {
	instance:          vk.Instance,
	physical_device:   vk.PhysicalDevice,
	device_properties: vk.PhysicalDeviceProperties,
	device:            vk.Device,
	queue:             vk.Queue,
	command_pool:      vk.CommandPool,
	descriptor_pool:   vk.DescriptorPool,
	command_buffer:    vk.CommandBuffer,
}

Vulkan_Pipeline :: struct {
	pipeline:              vk.Pipeline,
	layout:                vk.PipelineLayout,
	descriptor_set_layout: vk.DescriptorSetLayout,
	descriptor_set:        vk.DescriptorSet,
}

Vulkan_Buffer :: struct {
	buffer:     vk.Buffer,
	allocation: Vulkan_Allocation,
}

Vulkan_Allocation :: struct {
	memory: vk.DeviceMemory,
	size:   vk.DeviceSize,
}

Vulkan_Version :: bit_field u32 {
	patch: u32 | 12,
	minor: u32 | 10,
	major: u32 | 10,
}

@(require_results)
shader_create_hephaistos :: proc(
	ctx:          Vulkan_Context,
	path:         string,
	source:       string,
	shared_types: []typeid                   = {},
	defines:      map[string]hep.Const_Value = {},
) -> (module: vk.ShaderModule, ok: bool) {
	code, errors := hep.compile_shader(
		source,
		path,
		defines         = defines,
		shared_types    = shared_types,
		allocator       = context.temp_allocator,
		error_allocator = context.temp_allocator,
	)
	if len(errors) != 0 {
		lines := strings.split_lines(source, context.temp_allocator)
		for error in errors {
			hep.print_error(os.to_stream(os.stderr), path, lines, error)
		}
		return
	}
	_ = os.write_entire_file("a.spv", mem.slice_to_bytes(code))
	return shader_create_spirv(ctx, code)
}

debug_callback_proc :: proc "system" (
	messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT,
	messageTypes:    vk.DebugUtilsMessageTypeFlagsEXT,
	pCallbackData:  ^vk.DebugUtilsMessengerCallbackDataEXT,
	pUserData:       rawptr,
) -> b32 {
	context = runtime.default_context()
	severity: vk.DebugUtilsMessageSeverityFlagEXT
	switch {
	case .ERROR   in messageSeverity:
		severity = .ERROR
	case .WARNING in messageSeverity:
		severity = .WARNING
	case .INFO    in messageSeverity:
		severity = .INFO
	case .VERBOSE in messageSeverity:
		severity = .VERBOSE
	}
	if severity >= .WARNING {
		fmt.eprintfln("[%-7v]: %s", severity, pCallbackData.pMessage)
	}

	return false
}

@(require_results)
instance_create :: proc() -> (instance: vk.Instance) {
	when ENABLE_VALIDATION_LAYERS {
		extensions: []cstring = { vk.EXT_DEBUG_UTILS_EXTENSION_NAME, }
	} else {
		extensions: []cstring = {}
	}
	create_info := vk.InstanceCreateInfo {
    	sType                   = .INSTANCE_CREATE_INFO,
		pApplicationInfo        = &{
		    sType              = .APPLICATION_INFO,
		    pApplicationName   = "Hephaistos Compute Shader Example",
		    applicationVersion = cast(u32)Vulkan_Version{ major = 1, },
		    pEngineName        = "No Engine",
		    engineVersion      = cast(u32)Vulkan_Version{ major = 1, },
		    apiVersion         = cast(u32)Vulkan_Version{ major = 1, minor = 4, },
		},
		ppEnabledExtensionNames = raw_data(extensions),
		enabledExtensionCount   = u32(len(extensions)),
    }

	layer_count: u32
	vk.EnumerateInstanceLayerProperties(&layer_count, nil)
	layers := make([]vk.LayerProperties, layer_count, context.temp_allocator)
	vk.EnumerateInstanceLayerProperties(&layer_count, raw_data(layers))

	when ENABLE_VALIDATION_LAYERS {
		VALIDATION_LAYERS := [?]cstring{ "VK_LAYER_KHRONOS_validation", }
		outer: for name in VALIDATION_LAYERS {
			for &layer in layers {
				if name == cstring(&layer.layerName[0]) {
					continue outer
				}
			}
			fmt.eprintfln("ERROR: validation layer %s not available", name)
			os.exit(1)
		}

		create_info.ppEnabledLayerNames = &VALIDATION_LAYERS[0]
		create_info.enabledLayerCount   = len(VALIDATION_LAYERS)
		fmt.println("Validation layers loaded")

		create_info.pNext = &debug_create_info
	}

	if err := vk.CreateInstance(&create_info, nil, &instance); err != nil {
		fmt.eprintfln("Failed to create instance: %v", err)
		os.exit(1)
	}

	return instance
}

@(rodata)
debug_create_info := vk.DebugUtilsMessengerCreateInfoEXT {
	sType           = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
	messageSeverity = { .VERBOSE, .INFO, .WARNING, .ERROR, },
	messageType     = { .GENERAL, .VALIDATION, .PERFORMANCE, },
	pfnUserCallback = debug_callback_proc,
}

@(require_results)
debug_messenger_create :: proc(instance: vk.Instance) -> (debug_messenger: vk.DebugUtilsMessengerEXT) {
	result := vk.CreateDebugUtilsMessengerEXT(instance, &debug_create_info, nil, &debug_messenger)
	if result != nil {
		fmt.eprintfln("Failed to setup debug message callback (%v)", result)
	}

	return
}

debug_messenger_destroy :: proc(instance: vk.Instance, debug_messenger: vk.DebugUtilsMessengerEXT) {
	vk.DestroyDebugUtilsMessengerEXT(instance, debug_messenger, nil)
}

@(require_results)
pick_physical_device :: proc(instance: vk.Instance) -> (
	best_physical_device: vk.PhysicalDevice,
	device_properties:    vk.PhysicalDeviceProperties,
	queue_index:          u32,
	ok:                   bool,
) {
	physical_device_count: u32
	vk.EnumeratePhysicalDevices(instance, &physical_device_count, nil)
	physical_devices := make([]vk.PhysicalDevice, physical_device_count, context.temp_allocator)
	vk.EnumeratePhysicalDevices(instance, &physical_device_count, &physical_devices[0])

	best_score: int
	find_device_loop: for physical_device in physical_devices {
		props: vk.PhysicalDeviceProperties
		vk.GetPhysicalDeviceProperties(physical_device, &props)

		score := int(props.limits.maxImageDimension2D)
		if props.deviceType == .DISCRETE_GPU {
			score += 10000
		}

		extension_count: u32
		vk.EnumerateDeviceExtensionProperties(physical_device, nil, &extension_count, nil)
		extensions := make([]vk.ExtensionProperties, extension_count, context.temp_allocator)
		vk.EnumerateDeviceExtensionProperties(physical_device, nil, &extension_count, &extensions[0])

		queue_count: u32
		vk.GetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_count, nil)
		available_queues := make([]vk.QueueFamilyProperties, queue_count, context.temp_allocator)
		vk.GetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_count, raw_data(available_queues))

		new_queue_index := -1
		for q, i in available_queues {
			if .COMPUTE in q.queueFlags {
				new_queue_index = i
			}
		}

		if new_queue_index == -1 {
			continue
		}

		if score > best_score {
			best_physical_device = physical_device
			best_score           = score
			queue_index          = u32(new_queue_index)
			device_properties    = props
		}
	}

	if best_score == 0 {
		return
	}

	ok = true
	return
}

@(require_results)
shader_create_spirv :: proc(ctx: Vulkan_Context, data: []u32) -> (module: vk.ShaderModule, ok: bool) {
	create_info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(data) * size_of(u32),
		pCode    = raw_data(data),
	}
	if result := vk.CreateShaderModule(ctx.device, &create_info, nil, &module); result != nil {
		return
	}
	ok = true
	return
}

shader_create :: proc {
	shader_create_hephaistos,
	shader_create_spirv,
}

@(require_results)
device_create :: proc(physical_device: vk.PhysicalDevice, queue_index: u32) -> (device: vk.Device, queue: vk.Queue) {
	priority: f32 = 1
	queue_create_infos: []vk.DeviceQueueCreateInfo = {
		{
			sType            = .DEVICE_QUEUE_CREATE_INFO,
			queueCount       = 1,
			pQueuePriorities = &priority,
			queueFamilyIndex = queue_index,
		},
	}

	features: vk.PhysicalDeviceFeatures2 = {
		sType    = .PHYSICAL_DEVICE_FEATURES_2,
		features = {
			samplerAnisotropy = true,
		},
		pNext = &vk.PhysicalDeviceVulkan12Features {
			sType               = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
			bufferDeviceAddress = true,
			scalarBlockLayout   = true,
			pNext               = &vk.PhysicalDeviceVulkan11Features {
				sType                         = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
				variablePointers              = true,
				variablePointersStorageBuffer = true,
			},
		},
	}

	create_info := vk.DeviceCreateInfo {
		sType                = .DEVICE_CREATE_INFO,
		queueCreateInfoCount = u32(len(queue_create_infos)),
		pQueueCreateInfos    = raw_data(queue_create_infos),
		pEnabledFeatures     = nil,
		pNext                = &features,
	}

	if result := vk.CreateDevice(physical_device, &create_info, nil, &device); result != nil {
		fmt.eprintln("Failed to create device:", result)
		os.exit(1)
	}

	vk.GetDeviceQueue(device, queue_index, 0, &queue)

	return
}

@(require_results)
descriptor_pool_create :: proc(ctx: Vulkan_Context) -> (descriptor_pool: vk.DescriptorPool) {
	pool_sizes := []vk.DescriptorPoolSize {
		{ type = .STORAGE_IMAGE, descriptorCount = 2, },
	}
	descriptor_pool_create_info := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		poolSizeCount = u32(len(pool_sizes)),
		pPoolSizes    = raw_data(pool_sizes),
		maxSets       = 1,
	}
	if result := vk.CreateDescriptorPool(ctx.device, &descriptor_pool_create_info, nil, &descriptor_pool); result != nil {
		fmt.eprintln("Failed to create descriptor pool:", result)
		os.exit(1)
	}

	return
}

pipeline_destroy :: proc(ctx: Vulkan_Context, pipeline: Vulkan_Pipeline) {
	vk.DestroyPipelineLayout(ctx.device, pipeline.layout,   nil)
	vk.DestroyPipeline      (ctx.device, pipeline.pipeline, nil)
	vk.DestroyDescriptorSetLayout(ctx.device, pipeline.descriptor_set_layout, nil)
}

@(require_results)
create_command_pool :: proc(device: vk.Device, queue_index: u32) -> (command_pool: vk.CommandPool) {
	pool_create_info := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = { .RESET_COMMAND_BUFFER, },
		queueFamilyIndex = queue_index,
	}
	if result := vk.CreateCommandPool(device, &pool_create_info, nil, &command_pool); result != nil {
		fmt.eprintln("Failed to create command pool:", result)
		os.exit(1)
	}

	return
}

@(require_results)
allocate_command_buffer :: proc(
	device:       vk.Device,
	command_pool: vk.CommandPool,
	allocator := context.allocator,
) -> (command_buffer: vk.CommandBuffer, ok: bool) {
	command_buffer_allocate_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = command_pool,
		level              = .PRIMARY,
		commandBufferCount = 1,
	}

	if result := vk.AllocateCommandBuffers(device, &command_buffer_allocate_info, &command_buffer); result != nil {
		fmt.eprintln("Failed to allocate command buffer:", result)
		os.exit(1)
	}

	ok = true
	return
}

@(require_results)
find_memory_type :: proc(physical_device: vk.PhysicalDevice, type_filter: u32, properties: vk.MemoryPropertyFlags) -> (u32, bool) {
	memory_properties: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(physical_device, &memory_properties)

	for i in 0 ..< memory_properties.memoryTypeCount {
		if (type_filter & (1 << i)) != 0 && (memory_properties.memoryTypes[i].propertyFlags & properties) == properties {
			return i, true
	    }
	}

	return 0, false
}

buffer_destroy :: proc(ctx: Vulkan_Context, buffer: Vulkan_Buffer) {
	vk.FreeMemory(ctx.device, buffer.allocation.memory, nil)
	vk.DestroyBuffer(ctx.device, buffer.buffer, nil)
}

@(require_results)
buffer_create :: proc(
	ctx:   Vulkan_Context,
	size:  vk.DeviceSize,
	usage: vk.BufferUsageFlags,
) -> (buffer: vk.Buffer) {
	if result := vk.CreateBuffer(ctx.device, &{
	    sType       = .BUFFER_CREATE_INFO,
	    size        = size,
	    usage       = usage,
	    sharingMode = .EXCLUSIVE,
    }, nil, &buffer); result != nil {
		fmt.eprintln("Failed to create buffer:", result)
		os.exit(1)
    }

	return
}

@(require_results)
buffer_allocate :: proc(ctx: Vulkan_Context, buffer: vk.Buffer, properties: vk.MemoryPropertyFlags, shader_addressable := false) -> (allocation: Vulkan_Allocation) {
	requirements: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(ctx.device, buffer, &requirements)

	allocation = vulkan_allocate(ctx, requirements.size, requirements.memoryTypeBits, properties, shader_addressable)
	vk.BindBufferMemory(ctx.device, buffer, allocation.memory, 0)
	return
}

@(require_results)
image_view_create :: proc(
	ctx:    Vulkan_Context,
	image:  vk.Image,
	format: vk.Format,
	aspect: vk.ImageAspectFlag,
) -> (view: vk.ImageView) {
	create_info := vk.ImageViewCreateInfo {
		sType            = .IMAGE_VIEW_CREATE_INFO,
		image            = image,
		viewType         = .D2,
		format           = format,
		subresourceRange = {
			aspectMask     = { aspect, },
			baseMipLevel   = 0,
			levelCount     = 1,
			baseArrayLayer = 0,
			layerCount     = 1,
		},
	}
	if result := vk.CreateImageView(ctx.device, &create_info, nil, &view); result != nil {
		fmt.eprintln("Failed to create image view:", result)
		os.exit(1)
	}
	return
}

image_view_destroy :: proc(ctx: Vulkan_Context, view: vk.ImageView) {
	vk.DestroyImageView(ctx.device, view, nil)
}

@(require_results)
vulkan_allocate :: proc(
	ctx:              Vulkan_Context,
	size:             vk.DeviceSize,
	memory_type_bits: u32,
	properties:       vk.MemoryPropertyFlags,
	shader_addressable := false,
) -> (allocation: Vulkan_Allocation) {
	alloc_info := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = size,
		memoryTypeIndex = find_memory_type(ctx.physical_device, memory_type_bits, properties) or_else panic("Failed to find memory type"),
		pNext           = &vk.MemoryAllocateFlagsInfo {
			sType = .MEMORY_ALLOCATE_FLAGS_INFO,
			flags = { .DEVICE_ADDRESS, },
		} if shader_addressable else nil,
	}

	if result := vk.AllocateMemory(ctx.device, &alloc_info, nil, &allocation.memory); result != nil {
		fmt.eprintln("Failed to allocate memory:", result)
		os.exit(1)
	}
	allocation.size = size
	return
}

copy_buffer_to_image :: proc(ctx: Vulkan_Context, buffer: Vulkan_Buffer, image: vk.Image, width, height: u32) {
	region := vk.BufferImageCopy {
		bufferOffset      = 0,
		bufferRowLength   = 0,
		bufferImageHeight = 0,
		imageSubresource  = {
			aspectMask     = { .COLOR, },
			mipLevel       = 0,
			baseArrayLayer = 0,
			layerCount     = 1,
		},
		imageOffset = {0, 0, 0},
		imageExtent = {
			width,
			height,
			1,
		},
	}
	vk.CmdCopyBufferToImage(ctx.command_buffer, buffer.buffer, image, .GENERAL, 1, &region)
}

copy_image_to_buffer :: proc(ctx: Vulkan_Context, buffer: Vulkan_Buffer, image: vk.Image, width, height: u32) {
	region := vk.BufferImageCopy {
		bufferOffset      = 0,
		bufferRowLength   = 0,
		bufferImageHeight = 0,
		imageSubresource  = {
			aspectMask     = { .COLOR, },
			mipLevel       = 0,
			baseArrayLayer = 0,
			layerCount     = 1,
		},
		imageOffset = {0, 0, 0},
		imageExtent = {
			width,
			height,
			1,
		},
	}
	vk.CmdCopyImageToBuffer(ctx.command_buffer, image, .GENERAL, buffer.buffer, 1, &region)
}

image_destroy :: proc(ctx: Vulkan_Context, image: vk.Image) {
	vk.DestroyImage(ctx.device, image, nil)
}

@(require_results)
image_create :: proc(
	ctx:           Vulkan_Context,
	width, height: u32,
	format:        vk.Format,
	tiling:        vk.ImageTiling,
	usage:         vk.ImageUsageFlags,
	samples:       vk.SampleCountFlag = ._1,
) -> (image: vk.Image) {
	image_create_info := vk.ImageCreateInfo {
		sType         = .IMAGE_CREATE_INFO,
		imageType     = .D2,
		extent        = {
			width  = u32(width),
			height = u32(height),
			depth  = 1,
		},
		mipLevels     = 1,
		arrayLayers   = 1,
		tiling        = tiling,
		initialLayout = .UNDEFINED,
		usage         = usage,
		sharingMode   = .EXCLUSIVE,
		samples       = { samples, },
		format        = format,
	}

	if result := vk.CreateImage(ctx.device, &image_create_info, nil, &image); result != nil {
		fmt.eprintln("Failed to create image:", result)
		os.exit(1)
	}

	return
}

@(require_results)
image_allocate :: proc(ctx: Vulkan_Context, image: vk.Image, properties: vk.MemoryPropertyFlags) -> (allocation: Vulkan_Allocation) {
	requirements: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(ctx.device, image, &requirements)

	allocation = vulkan_allocate(ctx, requirements.size, requirements.memoryTypeBits, properties)
	vk.BindImageMemory(ctx.device, image, allocation.memory, 0)
	return
}

image_memory_barrier :: proc(
	ctx:                              Vulkan_Context,
	image:                            vk.Image,
	old_layout, new_layout:           vk.ImageLayout,
	src_stage, dst_stage:             vk.PipelineStageFlags,
	src_access_mask, dst_access_mask: vk.AccessFlags,
	aspect:                           vk.ImageAspectFlags = { .COLOR, },
) {
	barrier := vk.ImageMemoryBarrier {
		sType               = .IMAGE_MEMORY_BARRIER,
		oldLayout           = old_layout,
		newLayout           = new_layout,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image               = image,
		srcAccessMask       = src_access_mask,
		dstAccessMask       = dst_access_mask,
		subresourceRange = {
			aspectMask     = aspect,
			baseMipLevel   = 0,
			levelCount     = u32(1),
			baseArrayLayer = 0,
			layerCount     = 1,
		},
	}

	vk.CmdPipelineBarrier(
	    ctx.command_buffer,
	    src_stage,
	    dst_stage,
	    {},
	    0,
	    nil,
	    0,
	    nil,
	    1,
	    &barrier,
	)
}

@(require_results)
allocation_map :: proc(ctx: Vulkan_Context, allocation: Vulkan_Allocation, size: vk.DeviceSize) -> (addr: rawptr) {
	vk.MapMemory(ctx.device, allocation.memory, 0, size, {}, &addr)
	return
}

allocation_unmap :: proc(ctx: Vulkan_Context, allocation: Vulkan_Allocation) {
	vk.UnmapMemory(ctx.device, allocation.memory)
}

@(require_results)
buffer_create_with_data :: proc(ctx: Vulkan_Context, data: $S/[]$E) -> (buffer: Vulkan_Buffer) {
	size := vk.DeviceSize(len(data) * size_of(E))

	buffer.buffer     = buffer_create(ctx, size, { .TRANSFER_SRC, .TRANSFER_DST, })
	buffer.allocation = buffer_allocate(ctx, buffer.buffer, { .HOST_VISIBLE, .HOST_COHERENT, })

	mapped := cast([^]E)allocation_map(ctx, buffer.allocation, size)
	copy(mapped[:len(data)], data)
	allocation_unmap(ctx, buffer.allocation)
	return
}

Compute_Constants :: struct {
	background: [4]f32,
	foreground: [4]f32,
	noise:      f32,
}

@(require_results)
compute_pipeline_create :: proc(
	ctx:    Vulkan_Context,
	shader: vk.ShaderModule,
) -> (pipeline: Vulkan_Pipeline) {
	layout_bindings: []vk.DescriptorSetLayoutBinding = {
		{
			binding            = 0,
			descriptorCount    = 1,
			descriptorType     = .STORAGE_IMAGE,
			stageFlags         = { .COMPUTE, },
		},
		{
			binding            = 1,
			descriptorCount    = 1,
			descriptorType     = .STORAGE_IMAGE,
			stageFlags         = { .COMPUTE, },
		},
	}

	descriptor_set_layout_info := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = u32(len(layout_bindings)),
		pBindings    = raw_data(layout_bindings),
	}
	if result := vk.CreateDescriptorSetLayout(ctx.device, &descriptor_set_layout_info, nil, &pipeline.descriptor_set_layout); result != nil {
		fmt.eprintln("Failed to create descriptor set layout:", result)
		os.exit(1)
	}

	alloc_info := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = ctx.descriptor_pool,
		descriptorSetCount = 1,
		pSetLayouts        = &pipeline.descriptor_set_layout,
	}
	if result := vk.AllocateDescriptorSets(ctx.device, &alloc_info, &pipeline.descriptor_set); result != nil {
		fmt.eprintln("Failed to allocate descriptor sets:", result)
		os.exit(1)
	}

	layout_create_info := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = 1,
		pSetLayouts            = &pipeline.descriptor_set_layout,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &vk.PushConstantRange {
			stageFlags = { .COMPUTE, },
			offset     = 0,
			size       = size_of(Compute_Constants),
		},
	}
	if result := vk.CreatePipelineLayout(ctx.device, &layout_create_info, nil, &pipeline.layout); result != nil {
		fmt.eprintln("Failed to create compute pipeline layout:", result)
	}

	shader_stage_create_info := vk.PipelineShaderStageCreateInfo {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage  = { .COMPUTE, },
		module = shader,
		pName  = "main",
	}

	compute_create_info := vk.ComputePipelineCreateInfo {
		sType  = .COMPUTE_PIPELINE_CREATE_INFO,
		layout = pipeline.layout,
		stage  = shader_stage_create_info,
	}
	if result := vk.CreateComputePipelines(ctx.device, 0, 1, &compute_create_info, nil, &pipeline.pipeline); result != nil {
		fmt.eprintln("Failed to create compute pipeline:", result)
		os.exit(1)
	}

	return
}

main :: proc() {
	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		defer mem.tracking_allocator_destroy(&track)
		context.allocator = mem.tracking_allocator(&track)

		defer for _, leak in track.allocation_map {
			fmt.printf("%v leaked %m\n", leak.location, leak.size)
		}
	}

	vk.load_proc_addresses(rawptr(GetInstanceProcAddr))

	ctx: Vulkan_Context

	ctx.instance = instance_create()
	defer vk.DestroyInstance(ctx.instance, nil)
	vk.load_proc_addresses(ctx.instance)

	// when ENABLE_VALIDATION_LAYERS {
	// 	debug_messenger := debug_messenger_create(ctx.instance)
	// 	defer debug_messenger_destroy(ctx.instance, debug_messenger)
	// }

	queue_index: u32
	physical_device_found: bool
	ctx.physical_device, ctx.device_properties, queue_index, physical_device_found = pick_physical_device(ctx.instance)
	if !physical_device_found {
		fmt.eprintln("Failed to find suitable physical device")
		os.exit(1)
	}

	ctx.device, ctx.queue = device_create(ctx.physical_device, queue_index)
	defer vk.DestroyDevice(ctx.device, nil)

	ctx.command_pool = create_command_pool(ctx.device, queue_index)
	defer vk.DestroyCommandPool(ctx.device, ctx.command_pool, nil)

	command_buffer_ok: bool
	ctx.command_buffer, command_buffer_ok = allocate_command_buffer(ctx.device, ctx.command_pool)
	assert(command_buffer_ok)

	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
	}

	if result := vk.BeginCommandBuffer(ctx.command_buffer, &begin_info); result != nil {
		fmt.eprintln("Failed to begin recording command buffer:", result)
		os.exit(1)
	}

	ctx.descriptor_pool = descriptor_pool_create(ctx)
	defer vk.DestroyDescriptorPool(ctx.device, ctx.descriptor_pool, nil)

	COMPUTE_PATH   :: "compute.hep"
	compute_source := #load(COMPUTE_PATH, string)
	compute_shader := shader_create_hephaistos(ctx, COMPUTE_PATH, compute_source, { Compute_Constants, }) or_else panic("failed to create compute shader")
	defer vk.DestroyShaderModule(ctx.device, compute_shader, nil)

	pipeline := compute_pipeline_create(ctx, compute_shader)
	defer pipeline_destroy(ctx, pipeline)

	w          := 2048
	h          := 2048
	noise_data := make([]byte, w * h * 4)
	_           = rand.read(noise_data)
	defer delete(noise_data)

	input_image := image_create(ctx, u32(w), u32(h), .R8_UNORM, .OPTIMAL, { .STORAGE, .TRANSFER_DST, })
	defer image_destroy(ctx, input_image)

	input_image_allocation := image_allocate(ctx, input_image, { .DEVICE_LOCAL, })
	defer vk.FreeMemory(ctx.device, input_image_allocation.memory, nil)

	image_memory_barrier(
		ctx,
		input_image,
		.UNDEFINED,
		.GENERAL,
	    { .TOP_OF_PIPE, },
	    { .TRANSFER, },
	    {},
	    { .TRANSFER_WRITE, },
	)

	staging_buffer := buffer_create_with_data(ctx, noise_data)
	defer buffer_destroy(ctx, staging_buffer)

	copy_buffer_to_image(ctx, staging_buffer, input_image, u32(w), u32(h))

	image_memory_barrier(
		ctx,
		input_image,
		.GENERAL,
		.GENERAL,
	    { .TRANSFER, },
	    { .COMPUTE_SHADER, },
	    { .TRANSFER_WRITE, },
	    { .SHADER_READ, },
	)

	input_view := image_view_create(ctx, input_image, .R8_UNORM, .COLOR)
	defer image_view_destroy(ctx, input_view)


	output_image := image_create(ctx, u32(w), u32(h), .R8G8B8A8_UNORM, .OPTIMAL, { .STORAGE, .TRANSFER_SRC, })
	defer image_destroy(ctx, output_image)

	output_image_allocation := image_allocate(ctx, output_image, { .DEVICE_LOCAL, })
	defer vk.FreeMemory(ctx.device, output_image_allocation.memory, nil)

	image_memory_barrier(
		ctx,
		output_image,
		.UNDEFINED,
		.GENERAL,
	    { .TOP_OF_PIPE, },
	    { .COMPUTE_SHADER, },
	    {},
	    { .SHADER_WRITE, },
	)

	output_view := image_view_create(ctx, output_image, .R8G8B8A8_UNORM, .COLOR)
	defer image_view_destroy(ctx, output_view)

	descriptor_writes := []vk.WriteDescriptorSet {
		vk.WriteDescriptorSet {
		    sType           = .WRITE_DESCRIPTOR_SET,
		    dstSet          = pipeline.descriptor_set,
		    dstBinding      = 0,
		    descriptorType  = .STORAGE_IMAGE,
		    descriptorCount = 1,
		    pImageInfo      = &{
				imageView   = input_view,
				imageLayout = .GENERAL,
		    },
	    },
		vk.WriteDescriptorSet {
		    sType           = .WRITE_DESCRIPTOR_SET,
		    dstSet          = pipeline.descriptor_set,
		    dstBinding      = 1,
		    descriptorType  = .STORAGE_IMAGE,
		    descriptorCount = 1,
		    pImageInfo      = &{
				imageView   = output_view,
				imageLayout = .GENERAL,
		    },
	    },
	}
	vk.UpdateDescriptorSets(ctx.device, u32(len(descriptor_writes)), raw_data(descriptor_writes), 0, nil)

	vk.CmdBindPipeline(ctx.command_buffer, .COMPUTE, pipeline.pipeline)

	vk.CmdBindDescriptorSets(ctx.command_buffer, .COMPUTE, pipeline.layout, 0, 1, &pipeline.descriptor_set, 0, nil)

	compute_constants: Compute_Constants = {
		background = { 0.1, 0.1, 0.1, 1, },
		foreground = { 0.9, 0.9, 0.9, 1, },
		noise      = 0.02,
	}
	vk.CmdPushConstants(ctx.command_buffer, pipeline.layout, { .COMPUTE, }, 0, size_of(Compute_Constants), &compute_constants)

	vk.CmdDispatch(ctx.command_buffer, u32(w) / 8, u32(h) / 8, 1)

	image_memory_barrier(
		ctx,
		output_image,
		.GENERAL,
		.GENERAL,
	    { .COMPUTE_SHADER, },
	    { .TRANSFER, },
		{ .SHADER_WRITE, },
		{ .TRANSFER_READ, },
	)

	copy_image_to_buffer(ctx, staging_buffer, output_image, u32(w), u32(h))

	if result := vk.EndCommandBuffer(ctx.command_buffer); result != nil {
		fmt.eprintln("Failed to record command buffer:", result)
		os.exit(1)
	}

	fence: vk.Fence
	if result := vk.CreateFence(ctx.device, &{ sType = .FENCE_CREATE_INFO, }, nil, &fence); result != nil {
		fmt.eprintln("Failed to create fence:", result)
	}
	defer vk.DestroyFence(ctx.device, fence, nil)

	submit_info := vk.SubmitInfo {
		sType                = .SUBMIT_INFO,
		commandBufferCount   = 1,
		pCommandBuffers      = &ctx.command_buffer,
	}
	vk.QueueSubmit(ctx.queue, 1, &submit_info, fence)
	vk.WaitForFences(ctx.device, 1, &fence, true, ~u64(0))

	mapped := cast([^]byte)allocation_map(ctx, staging_buffer.allocation, vk.DeviceSize(w * h * 4))
	defer allocation_unmap(ctx, staging_buffer.allocation)

	pixels := make([]byte, w * h * 4, context.temp_allocator)
	copy(pixels, mapped[:w * h * 4])

	stbi.write_png("output.png", i32(w), i32(h), 4, raw_data(pixels), 0)
}
