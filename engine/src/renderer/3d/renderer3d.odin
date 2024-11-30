package sm_renderer_3d

import "core:log"
import "core:image/png"
import "core:slice"
import "core:math"
import "core:math/linalg"

import "sm:core"
import "sm:platform"
import "sm:rhi"

Error :: struct {
	message: string, // temp string
}
Result :: union { Error, rhi.RHI_Error }

init :: proc() -> Result {
	if r := init_rhi(); r != nil {
		return r.(rhi.RHI_Error)
	}

	return nil
}

shutdown :: proc() {
	shutdown_rhi()
	delete(g_r3d_state.main_render_pass.framebuffers)
}

draw :: proc() {
	maybe_image_index, acquire_res := rhi.wait_and_acquire_image()
	if acquire_res != nil {
		rhi.handle_error(&acquire_res.(rhi.RHI_Error))
		return
	}
	if maybe_image_index == nil {
		// No image available
		return
	}
	image_index := maybe_image_index.(uint)

	debug_update(&g_r3d_state.debug_renderer_state)

	fb := &g_r3d_state.main_render_pass.framebuffers[image_index]
	debug_submit_commands(&g_r3d_state.debug_renderer_state, fb^, g_r3d_state.main_render_pass.render_pass)

	if r := rhi.present(image_index); r != nil {
		rhi.handle_error(&r.(rhi.RHI_Error))
		return
	}
}

@(private)
init_rhi :: proc() -> RHI_Result {
	core.broadcaster_add_callback(&rhi.callbacks.on_recreate_swapchain_broadcaster, on_recreate_swapchain)

	// TODO: Presenting & swapchain framebuffers should be separated from the actual renderer
	// Get swapchain stuff
	main_window := platform.get_main_window()
	surface_index := rhi.get_surface_index_from_window(main_window)
	swapchain_format := rhi.get_swapchain_image_format(surface_index)
	swapchain_images := rhi.get_swapchain_images(surface_index)
	assert(len(swapchain_images) > 0)
	swapchain_dims := swapchain_images[0].dimensions

	// Make render pass for swapchain images
	g_r3d_state.main_render_pass.render_pass = rhi.create_render_pass(swapchain_format) or_return

	// Create global depth buffer
	g_r3d_state.depth_texture = rhi.create_depth_texture(swapchain_dims, .D24S8) or_return

	// Make framebuffers
	fb_textures := make([]^Texture_2D, len(swapchain_images), context.temp_allocator)
	for &im, i in swapchain_images {
		fb_textures[i] = &im
	}
	create_framebuffers(fb_textures, &g_r3d_state.depth_texture) or_return

	debug_init(&g_r3d_state.debug_renderer_state, g_r3d_state.main_render_pass.render_pass, swapchain_dims) or_return

	return nil
}

@(private)
shutdown_rhi :: proc() {
	rhi.wait_for_device()

	debug_shutdown(&g_r3d_state.debug_renderer_state)

	destroy_framebuffers()
	rhi.destroy_texture(&g_r3d_state.depth_texture)
	rhi.destroy_render_pass(&g_r3d_state.main_render_pass.render_pass)
}

@(private)
create_framebuffers :: proc(images: []^Texture_2D, depth: ^Texture_2D) -> rhi.RHI_Result {
	for &im, i in images {
		attachments := [2]^Texture_2D{im, depth}
		fb := rhi.create_framebuffer(g_r3d_state.main_render_pass.render_pass, attachments[:]) or_return
		append(&g_r3d_state.main_render_pass.framebuffers, fb)
	}
	return nil
}

@(private)
on_recreate_swapchain :: proc(args: rhi.Args_Recreate_Swapchain) {
	r: rhi.RHI_Result
	destroy_framebuffers()
	rhi.destroy_texture(&g_r3d_state.depth_texture)
	swapchain_images := rhi.get_swapchain_images(args.surface_index)
	g_r3d_state.depth_texture, r = rhi.create_depth_texture(args.new_dimensions, .D24S8)
	if r != nil {
		panic("Failed to recreate the depth texture.")
	}
	fb_textures := make([]^Texture_2D, len(swapchain_images), context.temp_allocator)
	for &im, i in swapchain_images {
		fb_textures[i] = &im
	}
	create_framebuffers(fb_textures, &g_r3d_state.depth_texture)
}

@(private)
destroy_framebuffers :: proc() {
	for &fb in g_r3d_state.main_render_pass.framebuffers {
		rhi.destroy_framebuffer(&fb)
	}
	clear(&g_r3d_state.main_render_pass.framebuffers)
}

Renderer3D_RenderPass :: struct {
	framebuffers: [dynamic]Framebuffer,
	render_pass: RHI_RenderPass,
}

Renderer3D_State :: struct {
	debug_renderer_state: Debug_Renderer_State,
	main_render_pass: Renderer3D_RenderPass,
	depth_texture: Texture_2D,
}
@(private)
g_r3d_state: Renderer3D_State
