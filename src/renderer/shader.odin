package renderer

import vk "vendor:vulkan"
import "core:os"
import "core:log"
import "core:path/filepath"

SHADER_DIR      :: #config(SHADER_DIR, ".")
SHADER_BIN_DIR  :: #config(SHADER_BIN_DIR, ".")

ShaderModule :: struct {
    module: vk.ShaderModule,
    stage:  vk.ShaderStageFlags,
}

@(private)
shader_module_create_from_file :: proc(renderer: ^Renderer, filename: string) -> vk.ShaderModule {
    shader_path, _ := filepath.join({SHADER_BIN_DIR, filename}, context.temp_allocator)
    code, read_err := os.read_entire_file(shader_path, context.temp_allocator)
    defer free_all(context.temp_allocator)
    if read_err != nil {
        log.errorf("Failed to read shader file %s: error %v", shader_path, read_err)
    }

    assert(len(code) % 4 == 0, "SPIR-V code length must be a multiple of 4 bytes!")

    shader_module_info := vk.ShaderModuleCreateInfo{
        sType       = vk.StructureType.SHADER_MODULE_CREATE_INFO,
        pNext       = nil,
        flags       = { },
        codeSize    = len(code),
        pCode       = cast(^u32)raw_data(code)
    }

    shader_module: vk.ShaderModule
    if vk.CreateShaderModule(renderer.logical_device, &shader_module_info, nil, &shader_module) != .SUCCESS {
        log.panicf("Failed to create shader module %s!", filename)
    }

    return shader_module
}

@(private)
shader_module_destroy :: proc(renderer: ^Renderer, shader_module: vk.ShaderModule) {
    vk.DestroyShaderModule(renderer.logical_device, shader_module, nil)
}

// WIP: I may not use this at all, but I don't want to throw it away yet
// // Initialize shader 'library' by finding all compiled spir-v shader code.
// @(private)
// shaders_init :: proc() {
//
//     // First, find shader files
//     global_shaders.files = make([dynamic]string)
//     global_shaders.compiled_code = make(map[string]^slang.IBlob)
//     // Walker <-> recursive directory iterator
//     shaders := os.walker_create_path(SHADER_DIR)
//     defer os.walker_destroy(&shaders)
//
//     for shader in os.walker_walk(&shaders) {
//         // First, check error
//         shader_path, err := os.walker_error(&shaders)
//         if err != nil {
//             log.errorf("Error iterating %s: %s\n", shader_path, err)
//             continue
//         }
//
//         // Then check if the file is a shader and add it to the list
//         if os.ext(shader.fullpath) == ".slang" {
//             new_shader := strings.clone(shader.fullpath)
//             append(&global_shaders.files, new_shader)
//         }
//     }
// }
//
// @(private)
// shaders_cleanup :: proc() {
//     for shader in global_shaders.files {
//         delete(shader)
//     }
//     delete(global_shaders.files)
//     delete(global_shaders.compiled_code)
// }
//
// @(private)
// report_diagnostics :: proc(shader_name: string, diagnostic: ^slang.IBlob) {
//     if diagnostic != nil {
//         log.errorf("Error in shader %s: %s", shader_name, cast([^]u8)diagnostic->getBufferPointer())
//     }
// }
//
// @(private)
// shaders_compile :: proc() {
//     global_session: ^slang.IGlobalSession
//     global_desc: slang.GlobalSessionDesc
//     if slang.createGlobalSession(int(global_desc.apiVersion), &global_session) != slang.OK {
//         log.panic("Failed to create slang global session!")
//     }
//     defer global_session->release()
//
//     // Compiling to spirv
//     target_desc := slang.TargetDesc{
//         format = .SPIRV,
//         profile = global_session.findProfile(global_session, "spirv_1_6")
//     }
//
//     options: [2]slang.CompilerOptionEntry = {
//         {slang.CompilerOptionName.EmitSpirvDirectly,
//             slang.CompilerOptionValue{slang.CompilerOptionValueKind.Int, 1, 0, nil, nil}},
//         {slang.CompilerOptionName.VulkanEmitReflection,
//             slang.CompilerOptionValue{slang.CompilerOptionValueKind.Int, 1, 0, nil, nil}},
//     }
//
//     session_desc := slang.SessionDesc{
//         defaultMatrixLayoutMode     = .COLUMN_MAJOR,
//         targetCount                 = 1,
//         targets                     = &target_desc,
//         compilerOptionEntryCount    = len(options),
//         compilerOptionEntries       = raw_data(options[:]),
//     }
//
//     session: ^slang.ISession
//     global_session->createSession(session_desc, &session)
//     defer session->release()
//
//     if len(global_shaders.files) < 1 {
//         log.warn("No shaders found in the shader directory!")
//     }
//     diagnostic: ^slang.IBlob
//
//     // Convert each of the shader files into modules
//     slang_modules := make([dynamic]^slang.IModule)
//     defer delete(slang_modules)
//     for file, i_shader in global_shaders.files {
//         module: ^slang.IModule = session->loadModule(strings.clone_to_cstring(file, context.temp_allocator), &diagnostic)
//         report_diagnostics(file, diagnostic)
//         diagnostic = nil
//         append(&slang_modules, module)
//     }
//
//     // Each shader file has one or more shader programs in it. We are going to extract
//     // each one from each file
//     for module, i_module in slang_modules {
//
//         // Find the entry points in the shader file for each shader program contained in it
//         entry_point_count := module->getDefinedEntryPointCount()
//         module_entry_points := make([]^slang.IEntryPoint, entry_point_count)
//         defer delete(module_entry_points)
//         for i_entry_point in 0..<entry_point_count {
//             entry_point: ^slang.IEntryPoint
//             module->getDefinedEntryPoint(i_entry_point, &entry_point)
//             if entry_point == nil {
//                 log.warnf("Shader %s: failed to find entry point!", module->getName())
//             }
//             module_entry_points[i_entry_point] = entry_point
//         }
//
//         // Compose the shader program
//         composed_programs: ^slang.IComponentType
//         program_components := make([dynamic]^slang.IComponentType)
//         defer delete(program_components)
//         append(&program_components, module)
//         for entry_point in module_entry_points {
//             append(&program_components, entry_point)
//         }
//         if session->createCompositeComponentType(raw_data(program_components), len(program_components), &composed_programs, &diagnostic) != slang.OK {
//             log.error("Failed to compose the shader module with entry points!")
//             report_diagnostics(string(module->getName()), diagnostic);
//             diagnostic = nil
//         }
//
//         // Link the composed programs
//         linked_program: ^slang.IComponentType
//         if composed_programs->link(&linked_program, &diagnostic) != slang.OK {
//             log.error("Failed to link the composed program!")
//             report_diagnostics(string(module->getName()), diagnostic);
//             diagnostic = nil
//         }
//
//         // Finally get the compiled target code for each entry point
//         program_layout: ^slang.ProgramLayout = linked_program->getLayout(0, &diagnostic)
//         if program_layout == nil {
//             log.error("Failed to get module reflection!")
//             report_diagnostics(string(module->getName()), diagnostic)
//             diagnostic = nil
//         }
//         for entry_point, i_entry_point in module_entry_points {
//             spirv_code: ^slang.IBlob
//             linked_program->getEntryPointCode(i_entry_point, 0, &spirv_code, &diagnostic)
//             //entry_point_refl: ^slang.EntryPointReflection = program_layout->getEntryPointByIndex(i_entry_point)
//             //linked_program->getEntryPointMetadata(i_entry_point, 0, &ep_metadata, &diagnostic)
//             if spirv_code == nil {
//                 log.error("Failed to get entry point data!")
//             }
//             //entry_point_name := slang.entry_point_getName(entry_point_refl)
//             //log.debugf("Found entry point: %s", entry_point_name)
//
//             //global_shaders.compiled_code[string(entry_point_name)] = spirv_code
//         }
//     }
//
//     // Cleanup
//     free_all(context.temp_allocator)
//     for module in slang_modules {
//         module->release()
//     }
// }
