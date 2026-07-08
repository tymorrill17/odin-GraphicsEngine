package renderer

import vk "vendor:vulkan"
import slang "thirdparty:slang"
import "core:os"
import "core:log"

SHADER_DIR :: #config(SHADER_DIR, ".")

Shader :: struct {
    module: vk.ShaderModule,
    stage:  vk.ShaderStageFlags,
}

ShaderModule :: struct {
    name: string,
    code: ^slang.IBlob,
}

shader_files: [dynamic]string

@(private)
get_shader_code :: proc(shader_name: string) -> (code: rawptr, length: u32) {
    return nil, 0
}

@(private)
shader_build_from_file :: proc(filepath: string) {

}

@(private)
shader_build_from_code :: proc(shader_name: string) {

}

// Initialization step for shader compilation. Counts how many shaders are in the
// shader dir, adds them to the set, and records mtimes. This is done once at the
// beginning so it doesn't have to be done throughout the runtime
@(private)
shaders_init :: proc() {

    // First, find shader files
    shader_files = make([dynamic]string)
    // Walker <-> recursive directory iterator
    shaders := os.walker_create_path(SHADER_DIR)
    defer os.walker_destroy(&shaders)

    for shader in os.walker_walk(&shaders) {
        // First, check error
        shader_path, err := os.walker_error(&shaders)
        if err != nil {
            log.errorf("Error iterating %s: %s\n", shader_path, err)
            continue
        }

        // Then check if the file is a shader and add it to the list
        if os.ext(shader.fullpath) == ".slang" {
            append(&shader_files, os.base(shader.fullpath))
        }
    }

    // Now that we have the number of shader files and their names, we can
    // compile them
    shaders_compile()
}

@(private)
shaders_cleanup :: proc() {
    delete(shader_files)
}

@(private)
shaders_check_updates :: proc() {
    for shader in shader_files {
        // Check to see if the shader has been modified, then compile it
    }
}

@(private)
shaders_compile :: proc() {
    global_session: ^slang.IGlobalSession
    global_desc: slang.GlobalSessionDesc
    if slang.createGlobalSession(int(global_desc.apiVersion), &global_session) != slang.OK {
        log.error("Failed to create slang global session!")
    }

}
