package renderer

import vk "vendor:vulkan"
import slang "thirdparty:slang"
import "core:os"
import "core:log"
import "core:strings"
import path "core:path/filepath"

SHADER_DIR :: #config(SHADER_DIR, ".")

Shader :: struct {
    module: vk.ShaderModule,
    stage:  vk.ShaderStageFlags,
}

ShaderGlobal :: struct {
    files:          [dynamic]string,
    compiled_code:  map[string]^slang.IBlob,
}

global_shaders: ShaderGlobal

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
    global_shaders.files = make([dynamic]string)
    global_shaders.compiled_code = make(map[string]^slang.IBlob)
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
            new_shader := strings.clone(shader.fullpath)
            append(&global_shaders.files, new_shader)
        }
    }

    // Now that we have the number of shader files and their names, we can
    // compile them
    shaders_compile()
}

@(private)
shaders_cleanup :: proc() {
    for shader in global_shaders.files {
        delete(shader)
    }
    delete(global_shaders.files)
    delete(global_shaders.compiled_code)
}

@(private)
shaders_check_updates :: proc() {
    for shader in global_shaders.files {
        // Check to see if the shader has been modified, then compile it
    }
}

@(private)
report_diagnostics :: proc(shader_name: string, diagnostic: ^slang.IBlob) {
    if diagnostic != nil {
        log.errorf("Error in shader %s: %s", shader_name, cast([^]u8)diagnostic->getBufferPointer())
    }
}

@(private)
shaders_compile :: proc() {
    global_session: ^slang.IGlobalSession
    global_desc: slang.GlobalSessionDesc
    if slang.createGlobalSession(int(global_desc.apiVersion), &global_session) != slang.OK {
        log.panic("Failed to create slang global session!")
    }
    defer global_session->release()

    // Compiling to spirv
    target_desc := slang.TargetDesc{
        format = .SPIRV,
        profile = global_session.findProfile(global_session, "spirv_1_6")
    }

    options: [2]slang.CompilerOptionEntry = {
        {slang.CompilerOptionName.EmitSpirvDirectly,
            slang.CompilerOptionValue{slang.CompilerOptionValueKind.Int, 1, 0, nil, nil}},
        {slang.CompilerOptionName.VulkanEmitReflection,
            slang.CompilerOptionValue{slang.CompilerOptionValueKind.Int, 1, 0, nil, nil}},
    }

    session_desc := slang.SessionDesc{
        defaultMatrixLayoutMode     = .COLUMN_MAJOR,
        targetCount                 = 1,
        targets                     = &target_desc,
        compilerOptionEntryCount    = len(options),
        compilerOptionEntries       = raw_data(options[:]),
    }

    session: ^slang.ISession
    global_session->createSession(session_desc, &session)
    defer session->release()

    if len(global_shaders.files) < 1 {
        log.warn("No shaders found in the shader directory!")
    }
    diagnostic: ^slang.IBlob

    // Convert each of the shader files into modules
    slang_modules := make([dynamic]^slang.IModule)
    defer delete(slang_modules)
    for file, i_shader in global_shaders.files {
        log.debug(file)
        module: ^slang.IModule = session->loadModule(strings.clone_to_cstring(file, context.temp_allocator), &diagnostic)
        append(&slang_modules, module)
        report_diagnostics(file, diagnostic)
    }

    // Each shader file has one or more shader programs in it. We are going to extract
    // each one from each file
    for module, i_module in slang_modules {

        // Find the entry points in the shader file for each shader program contained in it
        entry_point_count := module->getDefinedEntryPointCount()
        module_entry_points := make([]^slang.IEntryPoint, entry_point_count)
        defer delete(module_entry_points)
        for i_entry_point in 0..<entry_point_count {
            entry_point: ^slang.IEntryPoint
            module->getDefinedEntryPoint(i_entry_point, &entry_point)
            if entry_point == nil {
                log.warnf("Shader %s: failed to find entry point!", module->getName())
            }
            module_entry_points[i_entry_point] = entry_point
        }

        // Compose the shader program
        composed_programs:  ^slang.IComponentType
        program_components := make([dynamic]^slang.IComponentType)
        defer delete(program_components)
        append(&program_components, module)
        for entry_point in module_entry_points {
            append(&program_components, entry_point)
        }
        if session->createCompositeComponentType(raw_data(program_components), len(program_components), &composed_programs, &diagnostic) != slang.OK {
            report_diagnostics(string(module->getName()), diagnostic);
        }

        // Link the composed programs
        linked_program: ^slang.IComponentType
        if composed_programs->link(&linked_program, &diagnostic) != slang.OK {
            report_diagnostics(string(module->getName()), diagnostic);
        }

        // Finally get the compiled target code for each entry point
        program_layout: ^slang.ProgramLayout = linked_program->getLayout(0, &diagnostic)
        if program_layout == nil {
            report_diagnostics(string(module->getName()), diagnostic);
        }
        for entry_point, i_entry_point in module_entry_points {
            spirv_code: ^slang.IBlob
            linked_program->getEntryPointCode(i_entry_point, 0, &spirv_code, &diagnostic)
            entry_point_reflection: ^slang.EntryPointReflection = slang.program_layout_getEntryPointByIndex(program_layout, cast(uint)i_entry_point)
            if entry_point_reflection == nil {
                log.error("Failed to get reflection for entry point!")
            }
            entry_point_name := slang.entry_point_getName(entry_point_reflection)
            log.debugf("Found entry point: %s", entry_point_name)

            global_shaders.compiled_code[string(entry_point_name)] = spirv_code
        }
    }

    // Cleanup
    free_all(context.temp_allocator)
    for module in slang_modules {
        module->release()
    }
}
