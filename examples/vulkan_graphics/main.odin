// This example is using the bufferDeviceAddress extension, so it does not quite look like "normal" vulkan

package vk_graphics

import "base:runtime"

import "core:fmt"
import "core:os"
@(require)
import "core:mem"
import "core:time"
import "core:strings"

import "vendor:glfw"
import vk "vendor:vulkan"

import hep "../.."

ENABLE_VALIDATION_LAYERS :: #config(ENABLE_VALIDATION_LAYERS, ODIN_DEBUG)
MAX_FRAMES_IN_FLIGHT     :: #config(MAX_FRAMES_IN_FLIGHT,     2)
ENABLE_VSYNC             :: #config(ENABLE_VSYNC,             true)

Vulkan_Context :: struct {
	instance:          vk.Instance,
	physical_device:   vk.PhysicalDevice,
	device_properties: vk.PhysicalDeviceProperties,
	device:            vk.Device,
	queue:             vk.Queue,
	command_pool:      vk.CommandPool,
}

Vulkan_Pipeline :: struct {
	pipeline: vk.Pipeline,
	layout:   vk.PipelineLayout,
}

Vulkan_Swapchain :: struct {
	swapchain:      vk.SwapchainKHR,
	surface:        vk.SurfaceKHR,

	image_count:    u32,
	present_mode:   vk.PresentModeKHR,
	surface_format: vk.SurfaceFormatKHR,
	samples:        vk.SampleCountFlag,

	image_views:    []vk.ImageView,
	images:         []vk.Image,

	depth_format:   vk.Format,
	depth_view:     vk.ImageView,
	depth_image:    Vulkan_Image,

	color_view:     vk.ImageView,
	color_image:    Vulkan_Image,

	semaphores:     []vk.Semaphore,
}

Vulkan_Buffer :: struct {
	buffer:     vk.Buffer,
	allocation: Vulkan_Allocation,
}

Vulkan_Image :: struct {
	image:      vk.Image,
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
get_required_extensions :: proc() -> [dynamic]cstring {
	glfw_extensions := glfw.GetRequiredInstanceExtensions()
	ret             := make([dynamic]cstring, len(glfw_extensions), len(glfw_extensions) + 1, context.temp_allocator)
	copy(ret[:], glfw_extensions)

	when ENABLE_VALIDATION_LAYERS {
		append(&ret, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)
	}

	return ret
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
	extensions := get_required_extensions()
	create_info := vk.InstanceCreateInfo {
		sType                   = .INSTANCE_CREATE_INFO,
		pApplicationInfo        = &{
		    sType              = .APPLICATION_INFO,
		    pApplicationName   = "Hello Triangle",
		    applicationVersion = transmute(u32)Vulkan_Version{ major = 1, },
		    pEngineName        = "No Engine",
		    engineVersion      = transmute(u32)Vulkan_Version{ major = 1, },
		    apiVersion         = transmute(u32)Vulkan_Version{ major = 1, minor = 4, },
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

@(rodata)
device_extensions := []cstring {
	vk.KHR_SWAPCHAIN_EXTENSION_NAME,
}

@(require_results)
pick_physical_device :: proc(
	instance: vk.Instance,
	surface:  vk.SurfaceKHR,
) -> (
	best_physical_device: vk.PhysicalDevice,
	device_properties:    vk.PhysicalDeviceProperties,
	best_queue_index:     u32,
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

		features2: vk.PhysicalDeviceFeatures2 = {
			sType = .PHYSICAL_DEVICE_FEATURES_2,
		}
		vk.GetPhysicalDeviceFeatures2(physical_device, &features2)

		extension_count: u32
		vk.EnumerateDeviceExtensionProperties(physical_device, nil, &extension_count, nil)
		extensions := make([]vk.ExtensionProperties, extension_count, context.temp_allocator)
		vk.EnumerateDeviceExtensionProperties(physical_device, nil, &extension_count, &extensions[0])

		for req in device_extensions {
			found: bool
			for &ext in extensions {
				if cstring(&ext.extensionName[0]) == req {
					found = true
				}
			}
			if !found {
				continue find_device_loop
			}
		}

		queue_count: u32
		vk.GetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_count, nil)
		available_queues := make([]vk.QueueFamilyProperties, queue_count, context.temp_allocator)
		vk.GetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_count, raw_data(available_queues))

		queue_index := ~u32(0)
		for q, i in available_queues {
			if .GRAPHICS not_in q.queueFlags {
				continue
			}

			present: b32
			vk.GetPhysicalDeviceSurfaceSupportKHR(physical_device, u32(i), surface, &present)
			if present {
				queue_index = u32(i)
				break
			}
		}

		if queue_index == ~u32(0) {
			continue
		}

		if score > best_score {
			best_physical_device = physical_device
			best_score           = score
			best_queue_index     = queue_index
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
	module, ok = shader_create_spirv(ctx, code)
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

shader_destroy :: proc(ctx: Vulkan_Context, shader: vk.ShaderModule) {
	vk.DestroyShaderModule(ctx.device, shader, nil)
}

@(require_results)
get_surface_capabilities :: proc(
	device:  vk.PhysicalDevice,
	surface: vk.SurfaceKHR,
	allocator := context.allocator,
) -> (
	capabilities:  vk.SurfaceCapabilitiesKHR,
	formats:       []vk.SurfaceFormatKHR,
	present_modes: []vk.PresentModeKHR,
) {
	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(device, surface, &capabilities)

	format_count: u32
	vk.GetPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, nil)
	formats = make([]vk.SurfaceFormatKHR, format_count, allocator)
	vk.GetPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, raw_data(formats))

	present_mode_count: u32
	vk.GetPhysicalDeviceSurfacePresentModesKHR(device, surface, &present_mode_count, nil)
	present_modes = make([]vk.PresentModeKHR, present_mode_count, allocator)
	vk.GetPhysicalDeviceSurfacePresentModesKHR(device, surface, &present_mode_count, raw_data(present_modes))

	return
}

required_device_features: vk.PhysicalDeviceFeatures2 = {
	sType    = .PHYSICAL_DEVICE_FEATURES_2,
	features = {
		samplerAnisotropy = true,
	},
	pNext = &required_device_11_features,
}

required_device_11_features: vk.PhysicalDeviceVulkan11Features = {
	sType                         = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
	variablePointers              = true,
	variablePointersStorageBuffer = true,
	pNext                         = &required_device_12_features,
}

required_device_12_features: vk.PhysicalDeviceVulkan12Features = {
	sType                       = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
	bufferDeviceAddress         = true,
	scalarBlockLayout           = true,
	separateDepthStencilLayouts = true,
	pNext                       = &required_device_13_features,
}

required_device_13_features: vk.PhysicalDeviceVulkan13Features = {
	sType            = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
	dynamicRendering = true,
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

	create_info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		queueCreateInfoCount    = u32(len(queue_create_infos)),
		pQueueCreateInfos       = raw_data(queue_create_infos),
		enabledExtensionCount   = u32(len(device_extensions)),
		ppEnabledExtensionNames = raw_data(device_extensions),
		pNext                   = &required_device_features,
	}

	if result := vk.CreateDevice(physical_device, &create_info, nil, &device); result != nil {
		fmt.eprintln("Failed to create device:", result)
		os.exit(1)
	}

	vk.GetDeviceQueue(device, queue_index, 0, &queue)

	return
}

@(require_results)
surface_create :: proc(instance: vk.Instance, window: glfw.WindowHandle) -> (surface: vk.SurfaceKHR) {
	if result := glfw.CreateWindowSurface(instance, window, nil, &surface); result != nil {
		fmt.eprintfln("Failed to create window surface: %v", result)
		os.exit(1)
	}
	return
}

@(require_results)
choose_swapchain_parameters :: proc(ctx: Vulkan_Context, surface: vk.SurfaceKHR) -> (
	present_mode:   vk.PresentModeKHR,
	image_count:    u32,
	surface_format: vk.SurfaceFormatKHR,
) {
	capabilities, formats, present_modes := get_surface_capabilities(ctx.physical_device, surface, context.temp_allocator)

	present_mode = .FIFO
	if !ENABLE_VSYNC {
		for p in present_modes {
			if p == .MAILBOX {
				present_mode = p
				break
			}
		}
	}

	image_count = capabilities.minImageCount + 1
	if capabilities.maxImageCount != 0 && image_count > capabilities.maxImageCount {
		image_count = capabilities.maxImageCount
	}

	for format in formats {
		if format.format == .B8G8R8A8_SRGB && format.colorSpace == .SRGB_NONLINEAR {
			surface_format = format
			break
		}
	}

	return
}

pipeline_destroy :: proc(ctx: Vulkan_Context, pipeline: Vulkan_Pipeline) {
	vk.DestroyPipelineLayout(ctx.device, pipeline.layout,   nil)
	vk.DestroyPipeline      (ctx.device, pipeline.pipeline, nil)
}

@(require_results)
pipeline_create :: proc(
	ctx:            Vulkan_Context,
	color_format:   vk.Format,
	depth_format:   vk.Format,
	samples:        vk.SampleCountFlag,
	shader_module:  vk.ShaderModule,
	vertex_entry:   cstring = "main",
	fragment_entry: cstring = "main",
) -> (pipeline: Vulkan_Pipeline) {
	shader_stage_create_info := []vk.PipelineShaderStageCreateInfo {
		{
			sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage  = { .VERTEX, },
			module = shader_module,
			pName  = vertex_entry,
		},
		{
			sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage  = { .FRAGMENT, },
			module = shader_module,
			pName  = fragment_entry,
		},
	}

	dynamic_states := []vk.DynamicState {
		.VIEWPORT,
		.SCISSOR,
	}

	dynamic_state_create_info := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = u32(len(dynamic_states)),
		pDynamicStates    = raw_data(dynamic_states),
	}

	vertex_input_create_info := vk.PipelineVertexInputStateCreateInfo {
		sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
	}

	input_assembly_create_info := vk.PipelineInputAssemblyStateCreateInfo {
		sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = .TRIANGLE_LIST,
	}

	viewport_create_info := vk.PipelineViewportStateCreateInfo {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		scissorCount  = 1,
		pViewports    = nil,
		pScissors     = nil,
	}

	rasterizer_create_info := vk.PipelineRasterizationStateCreateInfo {
		sType                   = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		depthClampEnable        = false,
		rasterizerDiscardEnable = false,
		polygonMode             = .FILL,
		lineWidth               = 1,
		cullMode                = { .BACK, },
		frontFace               = .CLOCKWISE,
	}

	multisampling_create_info := vk.PipelineMultisampleStateCreateInfo {
		sType                 = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		sampleShadingEnable   = false,
		rasterizationSamples  = { samples, },
		minSampleShading      = 1,
		pSampleMask           = nil,
		alphaToCoverageEnable = false,
		alphaToOneEnable      = false,
	}

	color_blend_create_info := vk.PipelineColorBlendAttachmentState {
		colorWriteMask      = { .R, .G, .B, .A, },
		blendEnable         = false,
		srcColorBlendFactor = .ONE,
		dstColorBlendFactor = .ZERO,
		colorBlendOp        = .ADD,
		srcAlphaBlendFactor = .ONE,
		dstAlphaBlendFactor = .ZERO,
		alphaBlendOp        = .ADD,
	}

	blend_state_create_info := vk.PipelineColorBlendStateCreateInfo {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		logicOpEnable   = false,
		logicOp         = .COPY,
		attachmentCount = 1,
		pAttachments    = &color_blend_create_info,
		blendConstants  = 0,
	}

	pipeline_layout_create_info := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &vk.PushConstantRange {
			stageFlags = { .VERTEX, },
			offset     = 0,
			size       = size_of(Push_Constants),
		},
	}

	if result := vk.CreatePipelineLayout(ctx.device, &pipeline_layout_create_info, nil, &pipeline.layout); result != nil {
		fmt.eprintln("Failed to create pipeline layout:", result)
		os.exit(1)
	}

	depth_stencil_create_info := vk.PipelineDepthStencilStateCreateInfo {
		sType                 = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
		depthTestEnable       = true,
		depthWriteEnable      = true,
		depthCompareOp        = .LESS,
		depthBoundsTestEnable = false,
		minDepthBounds        = 0,
		maxDepthBounds        = 1,
		stencilTestEnable     = false,
	}

	color_format := color_format
	pipeline_create_info := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		stageCount          = u32(len(shader_stage_create_info)),
		pStages             = raw_data(shader_stage_create_info),
		pVertexInputState   = &vertex_input_create_info,
		pInputAssemblyState = &input_assembly_create_info,
		pViewportState      = &viewport_create_info,
		pRasterizationState = &rasterizer_create_info,
		pMultisampleState   = &multisampling_create_info,
		pDepthStencilState  = &depth_stencil_create_info,
		pColorBlendState    = &blend_state_create_info,
		pDynamicState       = &dynamic_state_create_info,
		layout              = pipeline.layout,
		renderPass          = 0,
		subpass             = 0,

		pNext = &vk.PipelineRenderingCreateInfo {
			sType                   = .PIPELINE_RENDERING_CREATE_INFO,
			colorAttachmentCount    = 1,
			pColorAttachmentFormats = &color_format,
			depthAttachmentFormat   = depth_format,
		},
	}

	if result := vk.CreateGraphicsPipelines(ctx.device, 0, 1, &pipeline_create_info, nil, &pipeline.pipeline); result != nil {
		fmt.eprintln("Failed to create graphics pipeline:", result)
		os.exit(1)
	}

	return
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
allocate_command_buffers :: proc(
	device:       vk.Device,
	command_pool: vk.CommandPool,
	n:            int,
	allocator := context.allocator,
) -> (command_buffers: []vk.CommandBuffer, ok: bool) {
	command_buffer_allocate_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = command_pool,
		level              = .PRIMARY,
		commandBufferCount = u32(n),
	}

	command_buffers = make([]vk.CommandBuffer, n, allocator)
	if result := vk.AllocateCommandBuffers(device, &command_buffer_allocate_info, raw_data(command_buffers)); result != nil {
		fmt.eprintln("Failed to allocate command buffer:", result)
		os.exit(1)
	}

	ok = true
	return
}

window: struct {
	handle:  glfw.WindowHandle,
	width:   int,
	height:  int,
	resized: bool,
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
	ctx:        Vulkan_Context,
	size:       vk.DeviceSize,
	usage:      vk.BufferUsageFlags,
	properties: vk.MemoryPropertyFlags,
	shader_addressable := false,
) -> (buffer: Vulkan_Buffer) {
	if result := vk.CreateBuffer(ctx.device, &{
	    sType       = .BUFFER_CREATE_INFO,
	    size        = size,
	    usage       = usage,
	    sharingMode = .EXCLUSIVE,
	}, nil, &buffer.buffer); result != nil {
		fmt.eprintln("Failed to create vertex buffer:", result)
		os.exit(1)
	}

	requirements: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(ctx.device, buffer.buffer, &requirements)

	buffer.allocation = vulkan_allocate(ctx, requirements.size, requirements.memoryTypeBits, properties, shader_addressable)
	vk.BindBufferMemory(ctx.device, buffer.buffer, buffer.allocation.memory, 0)

	return
}

buffer_copy :: proc(
	ctx:                 Vulkan_Context,
	dst, src:            Vulkan_Buffer,
	#any_int size:       vk.DeviceSize,
	#any_int src_offset: vk.DeviceSize = 0,
	#any_int dst_offset: vk.DeviceSize = 0,
) {
	command_buffer := COMMAND_BUFFER_SINGLE_SCOPED(ctx)

	vk.CmdCopyBuffer(command_buffer, src.buffer, dst.buffer, 1, &vk.BufferCopy{
		srcOffset = src_offset,
		dstOffset = dst_offset,
		size      = size,
	})
}

@(require_results)
staging_buffer_create :: proc(ctx: Vulkan_Context, data: $S/[]$E) -> (buffer: Vulkan_Buffer) {
	size := vk.DeviceSize(len(data) * size_of(E))

	buffer = buffer_create(
		ctx,
		size,
		{ .TRANSFER_SRC, },
		{ .HOST_VISIBLE, .HOST_COHERENT, },
	)

	mapped := cast([^]E)allocation_map(ctx, buffer.allocation, size)
	copy(mapped[:len(data)], data)
	allocation_unmap(ctx, buffer.allocation)
	return
}

Vertex :: struct {
	position:   [2]f32,
	tex_coords: [2]f32,
}

Push_Constants :: struct {
	vertex_buffer: hep.Buffer_Address(Vertex),
}

swapchain_destroy :: proc(ctx: Vulkan_Context, swapchain: Vulkan_Swapchain) {
	image_view_destroy(ctx, swapchain.color_view)
	image_destroy(ctx, swapchain.color_image)

	image_view_destroy(ctx, swapchain.depth_view)
	image_destroy(ctx, swapchain.depth_image)

	for view in swapchain.image_views {
		image_view_destroy(ctx, view)
	}
	delete(swapchain.image_views)
	delete(swapchain.images)
	vk.DestroySwapchainKHR(ctx.device, swapchain.swapchain, nil)

	for sema in swapchain.semaphores {
		vk.DestroySemaphore(ctx.device, sema, nil)
	}
	delete(swapchain.semaphores)
}

@(require_results)
image_view_create :: proc(
	ctx:    Vulkan_Context,
	image:  vk.Image,
	format: vk.Format,
	aspect: vk.ImageAspectFlag,
	levels: int = 1,
) -> (view: vk.ImageView) {
	create_info := vk.ImageViewCreateInfo {
		sType            = .IMAGE_VIEW_CREATE_INFO,
		image            = image,
		viewType         = .D2,
		format           = format,
		subresourceRange = {
			aspectMask     = { aspect, },
			baseMipLevel   = 0,
			levelCount     = u32(levels),
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
swapchain_create :: proc(
	ctx:             Vulkan_Context,
	surface:         vk.SurfaceKHR,
	min_image_count: u32,
	present_mode:    vk.PresentModeKHR,
	surface_format:  vk.SurfaceFormatKHR,
	depth_format:    vk.Format,
	samples:         vk.SampleCountFlag,
) -> (swapchain: Vulkan_Swapchain) {
	swapchain.surface        = surface
	swapchain.present_mode   = present_mode
	swapchain.surface_format = surface_format
	swapchain.depth_format   = depth_format
	swapchain.samples        = samples

	swapchain.depth_image = image_create(
		ctx,
		u32(window.width),
		u32(window.height),
		depth_format,
		.OPTIMAL,
		{ .DEPTH_STENCIL_ATTACHMENT, },
		{ .DEVICE_LOCAL, },
		samples = samples,
	)
	swapchain.color_image = image_create(
		ctx,
		u32(window.width),
		u32(window.height),
		surface_format.format,
		.OPTIMAL,
		{ .COLOR_ATTACHMENT, .TRANSIENT_ATTACHMENT, },
		{ .DEVICE_LOCAL, },
		samples = samples,
	)

	swapchain.color_view = image_view_create(ctx, swapchain.color_image.image, surface_format.format, .COLOR)
	swapchain.depth_view = image_view_create(ctx, swapchain.depth_image.image, depth_format, .DEPTH)

	swaphain_create_info := vk.SwapchainCreateInfoKHR {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		surface          = surface,
		minImageCount    = min_image_count,
		imageFormat      = surface_format.format,
		imageColorSpace  = surface_format.colorSpace,
		imageExtent      = { u32(window.width), u32(window.height), },
		imageArrayLayers = 1,
		imageUsage       = { .COLOR_ATTACHMENT, },
		imageSharingMode = .EXCLUSIVE,
		preTransform     = { .IDENTITY, },
		compositeAlpha   = { .OPAQUE, },
		presentMode      = present_mode,
		clipped          = true,
	}

	if result := vk.CreateSwapchainKHR(ctx.device, &swaphain_create_info, nil, &swapchain.swapchain); result != nil {
		fmt.eprintln("Failed to create swapchain:", result)
		os.exit(1)
	}

	vk.GetSwapchainImagesKHR(ctx.device, swapchain.swapchain, &swapchain.image_count, nil)
	swapchain.images = make([]vk.Image, swapchain.image_count)
	vk.GetSwapchainImagesKHR(ctx.device, swapchain.swapchain, &swapchain.image_count, raw_data(swapchain.images))

	swapchain.image_views = make([]vk.ImageView, swapchain.image_count)
	for &view, i in swapchain.image_views {
		view = image_view_create(ctx, swapchain.images[i], surface_format.format, .COLOR)
	}

	swapchain.semaphores = make([]vk.Semaphore, swapchain.image_count)
	for &sema in swapchain.semaphores {
		create_info := vk.SemaphoreCreateInfo { sType = .SEMAPHORE_CREATE_INFO, }
		if result := vk.CreateSemaphore(ctx.device, &create_info, nil, &sema); result != nil {
			fmt.eprintln("Failed to create swapchain semaphore:", result)
			os.exit(1)
		}
	}

	return
}

swapchain_recreate :: proc(
	ctx:         Vulkan_Context,
	swapchain:  ^Vulkan_Swapchain,
) {
	vk.DeviceWaitIdle(ctx.device)
	swapchain_destroy(ctx, swapchain^)
	swapchain^ = swapchain_create(
    	ctx,
    	swapchain.surface,
    	swapchain.image_count,
    	swapchain.present_mode,
    	swapchain.surface_format,
    	swapchain.depth_format,
    	swapchain.samples,
    )
}

@(require_results, deferred_in_out=command_buffer_end_single)
COMMAND_BUFFER_SINGLE_SCOPED :: proc(ctx: Vulkan_Context) -> vk.CommandBuffer {
	return command_buffer_begin_single(ctx)
}

@(require_results)
command_buffer_begin_single :: proc(ctx: Vulkan_Context) -> vk.CommandBuffer {
	alloc_info := vk.CommandBufferAllocateInfo {
	    sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
	    level              = .PRIMARY,
	    commandPool        = ctx.command_pool,
	    commandBufferCount = 1,
	}

	command_buffer: vk.CommandBuffer
	if result := vk.AllocateCommandBuffers(ctx.device, &alloc_info, &command_buffer); result != nil {
		fmt.eprintln("Failed to allocate command buffer:", result)
		os.exit(1)
	}

	vk.BeginCommandBuffer(command_buffer, &{
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = { .ONE_TIME_SUBMIT, },
	})
	return command_buffer
}

command_buffer_end_single :: proc(ctx: Vulkan_Context, command_buffer: vk.CommandBuffer) {
	command_buffer := command_buffer
	vk.EndCommandBuffer(command_buffer)

	vk.QueueSubmit(ctx.queue, 1, &vk.SubmitInfo{
		sType              = .SUBMIT_INFO,
		commandBufferCount = 1,
		pCommandBuffers    = &command_buffer,
	}, 0)
	vk.QueueWaitIdle(ctx.queue)

	vk.FreeCommandBuffers(ctx.device, ctx.command_pool, 1, &command_buffer)
}

image_destroy :: proc(ctx: Vulkan_Context, image: Vulkan_Image) {
	vk.FreeMemory(ctx.device, image.allocation.memory, nil)
	vk.DestroyImage(ctx.device, image.image, nil)
}

@(require_results)
image_create :: proc(
	ctx:           Vulkan_Context,
	width, height: u32,
	format:        vk.Format,
	tiling:        vk.ImageTiling,
	usage:         vk.ImageUsageFlags,
	properties:    vk.MemoryPropertyFlags,
	samples:       vk.SampleCountFlag = ._1,
) -> (image: Vulkan_Image) {
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

	if result := vk.CreateImage(ctx.device, &image_create_info, nil, &image.image); result != nil {
		fmt.eprintln("Failed to create image:", result)
		os.exit(1)
	}

	requirements: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(ctx.device, image.image, &requirements)

	image.allocation = vulkan_allocate(ctx, requirements.size, requirements.memoryTypeBits, properties)
	vk.BindImageMemory(ctx.device, image.image, image.allocation.memory, 0)

	return
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
		pNext           = &vk.MemoryPriorityAllocateInfoEXT {
			sType    = .MEMORY_PRIORITY_ALLOCATE_INFO_EXT,
			priority = 1,
			pNext    = &vk.MemoryAllocateFlagsInfo {
				sType = .MEMORY_ALLOCATE_FLAGS_INFO,
				flags = { .DEVICE_ADDRESS, },
			} if shader_addressable else nil,
		},
	}

	if result := vk.AllocateMemory(ctx.device, &alloc_info, nil, &allocation.memory); result != nil {
		fmt.eprintln("Failed to allocate memory:", result)
		os.exit(1)
	}
	allocation.size = size
	return
}

image_memory_barrier :: proc(
	ctx:                              Vulkan_Context,
	command_buffer:                   vk.CommandBuffer,
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
	    command_buffer,
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
choose_image_format :: proc(
	ctx:        Vulkan_Context,
	candidates: []vk.Format,
	tiling:     vk.ImageTiling,
	features:   vk.FormatFeatureFlags,
) -> (vk.Format, bool) {
	for format in candidates {
		format_properties: vk.FormatProperties
		vk.GetPhysicalDeviceFormatProperties(ctx.physical_device, format, &format_properties)

		#partial switch tiling {
		case .LINEAR:
			if features <= format_properties.linearTilingFeatures {
				return format, true
			}
		case .OPTIMAL:
			if features <= format_properties.optimalTilingFeatures {
				return format, true
			}
		}
	}
	return {}, false
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
	glfw.Init()
	defer glfw.Terminate()

	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	window.handle = glfw.CreateWindow(900, 600, "Hello Vulkan", nil, nil)
	window.width  = 900
	window.height = 600
	defer glfw.DestroyWindow(window.handle)

	vk.load_proc_addresses(proc(p: rawptr, name: cstring) {
		(cast(^rawptr)p)^ = glfw.GetInstanceProcAddress(nil, name)
	})

	ctx: Vulkan_Context
	ctx.instance = instance_create()
	defer vk.DestroyInstance(ctx.instance, nil)
	vk.load_proc_addresses(ctx.instance)

	when ENABLE_VALIDATION_LAYERS {
		debug_messenger := debug_messenger_create(ctx.instance)
		defer debug_messenger_destroy(ctx.instance, debug_messenger)
	}

	surface := surface_create(ctx.instance, window.handle)
	defer vk.DestroySurfaceKHR(ctx.instance, surface, nil)

	queue_index: u32
	physical_device_found: bool
	ctx.physical_device, ctx.device_properties, queue_index, physical_device_found = pick_physical_device(ctx.instance, surface)
	if !physical_device_found {
		fmt.eprintln("Failed to find suitable physical device")
		os.exit(1)
	}

	ctx.device, ctx.queue = device_create(ctx.physical_device, queue_index)
	defer vk.DestroyDevice(ctx.device, nil)

	ctx.command_pool = create_command_pool(ctx.device, queue_index)
	defer vk.DestroyCommandPool(ctx.device, ctx.command_pool, nil)

	present_mode, min_image_count, surface_format := choose_swapchain_parameters(ctx, surface)

	counts := ctx.device_properties.limits.framebufferColorSampleCounts & ctx.device_properties.limits.framebufferDepthSampleCounts
	max_sample_count := vk.SampleCountFlag._1
	#reverse for count in counts {
		max_sample_count = count
		break
	}

	depth_format := choose_image_format(
		ctx,
		{ .D24_UNORM_S8_UINT, .X8_D24_UNORM_PACK32, .D16_UNORM, .D32_SFLOAT_S8_UINT, .D32_SFLOAT, },
		.OPTIMAL,
		{ .DEPTH_STENCIL_ATTACHMENT, },
	) or_else panic("Failed to find suitable image format for depth buffer")

	SHADER_PATH   :: "shader.hep"
	shader_source := #load(SHADER_PATH, string)
	shader_module := shader_create(ctx, SHADER_PATH, shader_source, { Push_Constants, }) or_else panic("failed to compile shader")
	defer shader_destroy(ctx, shader_module)

	pipeline := pipeline_create(
		ctx,
		surface_format.format,
		depth_format,
		max_sample_count,
		shader_module,
	)
	defer pipeline_destroy(ctx, pipeline)

	swapchain := swapchain_create(ctx, surface, min_image_count, present_mode, surface_format, depth_format, max_sample_count)
	defer swapchain_destroy(ctx, swapchain)

	command_buffers, command_buffer_ok := allocate_command_buffers(ctx.device, ctx.command_pool, int(swapchain.image_count))
	if !command_buffer_ok {
		os.exit(1)
	}
	defer delete(command_buffers)

	image_available_semaphores := make([]vk.Semaphore, MAX_FRAMES_IN_FLIGHT)
	in_flight_fences           := make([]vk.Fence,     MAX_FRAMES_IN_FLIGHT)
	defer delete(image_available_semaphores)
	defer delete(in_flight_fences)

	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		semaphore_create_info := vk.SemaphoreCreateInfo {
			sType = .SEMAPHORE_CREATE_INFO,
		}
		fence_create_info := vk.FenceCreateInfo {
			sType = .FENCE_CREATE_INFO,
			flags = { .SIGNALED, },
		}

		vk.CreateSemaphore(ctx.device, &semaphore_create_info, nil, &image_available_semaphores[i])
		vk.CreateFence    (ctx.device, &fence_create_info,     nil, &in_flight_fences[i])
	}

	defer for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		vk.DestroySemaphore(ctx.device, image_available_semaphores[i], nil)
		vk.DestroyFence    (ctx.device, in_flight_fences[i],           nil)
	}

	glfw.SetFramebufferSizeCallback(window.handle, glfw_resize_callback)
	glfw_resize_callback :: proc "c" (window_handle: glfw.WindowHandle, width, height: i32) {
		window.width  = max(int(width ), 1)
		window.height = max(int(height), 1)
		window.resized = true
	}

	vertices: []Vertex = {
		{ position = {  0.5,  0.5, }, tex_coords = { 0, 0, }, },
		{ position = { -0.5,  0.5, }, tex_coords = { 0, 1, }, },
		{ position = {    0, -0.5, }, tex_coords = { 1, 0, }, },
	}

	vertex_buffer := buffer_create(
		ctx,
		vk.DeviceSize(size_of(Vertex) * len(vertices)),
		{ .SHADER_DEVICE_ADDRESS, .TRANSFER_DST, },
		{ .DEVICE_LOCAL, },
		true,
	)
	defer buffer_destroy(ctx, vertex_buffer)

	staging_buffer := staging_buffer_create(ctx, vertices)
	buffer_copy(ctx, vertex_buffer, staging_buffer, size_of(Vertex) * len(vertices))

	buffer_destroy(ctx, staging_buffer)

	last_print_time    := time.now()
	frames_since_print := 0

	current_frame: int
	main_loop: for !glfw.WindowShouldClose(window.handle) {
		if window.resized {
			swapchain_recreate(ctx, &swapchain)
			window.resized = false
			continue main_loop
		}

		vk.WaitForFences(ctx.device, 1, &in_flight_fences[current_frame], true, max(u64))

		frames_since_print += 1
		if time.since(last_print_time) > time.Second {
			glfw.SetWindowTitle(window.handle, fmt.ctprintf("%v", frames_since_print))
			frames_since_print = 0
			last_print_time    = time.now()
		}

		image_index: u32
		acquire_image_result := vk.AcquireNextImageKHR(
			ctx.device,
			swapchain.swapchain,
			max(u64),
			image_available_semaphores[current_frame],
			0,
			&image_index,
		)
		#partial switch acquire_image_result {
		case nil, .SUBOPTIMAL_KHR:
		case .ERROR_OUT_OF_DATE_KHR:
			swapchain_recreate(ctx, &swapchain)
			continue main_loop
		case:
			fmt.eprintln("Failed to acquire swapchain image:", acquire_image_result)
			os.exit(1)
		}

		vk.ResetFences(ctx.device, 1, &in_flight_fences[current_frame])

		vk.ResetCommandBuffer(command_buffers[current_frame], {})

		{
			command_buffer := command_buffers[current_frame]

			begin_info := vk.CommandBufferBeginInfo {
				sType = .COMMAND_BUFFER_BEGIN_INFO,
			}

			if result := vk.BeginCommandBuffer(command_buffer, &begin_info); result != nil {
				fmt.eprintln("Failed to begin recording command buffer:", result)
				os.exit(1)
			}

			image_memory_barrier(
				ctx,
				command_buffer,
				swapchain.images[image_index],
				.UNDEFINED,
				.COLOR_ATTACHMENT_OPTIMAL,
				{ .COLOR_ATTACHMENT_OUTPUT, },
				{ .COLOR_ATTACHMENT_OUTPUT, },
				{},
				{ .COLOR_ATTACHMENT_WRITE, },
			)

			image_memory_barrier(
				ctx,
				command_buffer,
				swapchain.color_image.image,
				.UNDEFINED,
				.COLOR_ATTACHMENT_OPTIMAL,
				{ .COLOR_ATTACHMENT_OUTPUT, },
				{ .COLOR_ATTACHMENT_OUTPUT, },
				{ .COLOR_ATTACHMENT_WRITE, },
				{ .COLOR_ATTACHMENT_WRITE, },
			)

			image_memory_barrier(
				ctx,
				command_buffer,
				swapchain.depth_image.image,
				.UNDEFINED,
				.DEPTH_ATTACHMENT_OPTIMAL,
				{ .EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS, },
				{ .EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS, },
				{ .DEPTH_STENCIL_ATTACHMENT_WRITE, },
				{ .DEPTH_STENCIL_ATTACHMENT_WRITE, },
				aspect = { .DEPTH, },
			)

			vk.CmdSetViewport(command_buffer, 0, 1, &vk.Viewport{
				x        = 0,
				y        = 0,
				width    = f32(window.width),
				height   = f32(window.height),
				minDepth = 0,
				maxDepth = 1,
			})

			vk.CmdSetScissor(command_buffer, 0, 1, &vk.Rect2D{
				offset = {},
				extent = { u32(window.width), u32(window.height), },
			})

			color_attachment := vk.RenderingAttachmentInfo {
				sType              = .RENDERING_ATTACHMENT_INFO,
				imageView          = swapchain.color_view,
				imageLayout        = .COLOR_ATTACHMENT_OPTIMAL,
				loadOp             = .CLEAR,
				storeOp            = .STORE,
				clearValue         = { color = { float32 = 0, }, },
				resolveMode        = { .AVERAGE, },
				resolveImageView   = swapchain.image_views[image_index],
				resolveImageLayout = .COLOR_ATTACHMENT_OPTIMAL,
			}
			depth_attachment := vk.RenderingAttachmentInfo {
				sType       = .RENDERING_ATTACHMENT_INFO,
				imageView   = swapchain.depth_view,
				imageLayout = .DEPTH_ATTACHMENT_OPTIMAL,
				loadOp      = .CLEAR,
				storeOp     = .DONT_CARE,
				clearValue  = { depthStencil = { depth = 1, }, },
			}

			vk.CmdBeginRendering(command_buffer, &{
				sType      = .RENDERING_INFO,
				renderArea = {
					offset = {},
					extent = { u32(window.width), u32(window.height), },
				},
				layerCount           = 1,
				colorAttachmentCount = 1,
				pColorAttachments    = &color_attachment,
				pDepthAttachment     = &depth_attachment,
			})

			vk.CmdBindPipeline(command_buffer, .GRAPHICS, pipeline.pipeline)

			push_constants := Push_Constants {
				vertex_buffer = {
					address = vk.GetBufferDeviceAddress(ctx.device, &{
						sType  = .BUFFER_DEVICE_ADDRESS_INFO,
						buffer = vertex_buffer.buffer,
					}),
				},
			}
			vk.CmdPushConstants(command_buffer, pipeline.layout, { .VERTEX, }, 0, size_of(Push_Constants), &push_constants)

			vk.CmdDraw(command_buffer, u32(len(vertices)), 1, 0, 0)

			vk.CmdEndRendering(command_buffer)

			image_memory_barrier(
				ctx,
				command_buffer,
				swapchain.images[image_index],
				.COLOR_ATTACHMENT_OPTIMAL,
				.PRESENT_SRC_KHR,
				{ .COLOR_ATTACHMENT_OUTPUT, },
				{ .BOTTOM_OF_PIPE, },
				{ .COLOR_ATTACHMENT_WRITE, },
				{},
			)

			if result := vk.EndCommandBuffer(command_buffer); result != nil {
				fmt.eprintln("Failed to end command buffer:", result)
			}
		}

		wait_semaphores := []vk.Semaphore {
			image_available_semaphores[current_frame],
		}
		submit_info := vk.SubmitInfo {
			sType                = .SUBMIT_INFO,
			waitSemaphoreCount   = u32(len(wait_semaphores)),
			pWaitSemaphores      = raw_data(wait_semaphores),
			pWaitDstStageMask    = &vk.PipelineStageFlags{ .COLOR_ATTACHMENT_OUTPUT, },
			commandBufferCount   = 1,
			pCommandBuffers      = &command_buffers[current_frame],
			signalSemaphoreCount = 1,
			pSignalSemaphores    = &swapchain.semaphores[image_index],
		}

		if result := vk.QueueSubmit(ctx.queue, 1, &submit_info, in_flight_fences[current_frame]); result != nil {
			fmt.eprintln("Failed to submit draw command buffer:", result)
			break
		}

		present_result := vk.QueuePresentKHR(ctx.queue, &{
			sType              = .PRESENT_INFO_KHR,
			waitSemaphoreCount = 1,
			pWaitSemaphores    = &swapchain.semaphores[image_index],
			swapchainCount     = 1,
			pSwapchains        = &swapchain.swapchain,
			pImageIndices      = &image_index,
		})
		#partial switch present_result {
		case nil, .SUBOPTIMAL_KHR:
		case .ERROR_OUT_OF_DATE_KHR:
			swapchain_recreate(ctx, &swapchain)
			continue main_loop
		case:
			fmt.eprintln("Failed to present:", present_result)
			os.exit(1)
		}

		glfw.PollEvents()

		current_frame = (current_frame + 1) % MAX_FRAMES_IN_FLIGHT

		free_all(context.temp_allocator)
	}

	vk.QueueWaitIdle(ctx.queue)
}
