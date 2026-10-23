// SPDX-License-Identifier: MIT
//! Wires the runtime loader, library descriptor, generated dispatch, and sync binding.
//! The runtime route does not link the native library.

const std = @import("std");

/// Must match the symbol prefix in `runtime/library.zig` for this SDK's sync binding.
const sync_prefix = "luajit_rt";

/// C-library externs that must stay direct rather than route to the LuaJIT provider.
/// Names are the union across target headers; undeclared names are ignored.
/// Includes fortified glibc stdio aliases emitted in optimized translations.
const libc_noise =
    \\_LIBC_COUNT,_LIBC_SINGLE_BY_DEFAULT,__MINGW_GNU_PRINTF,
    \\__MINGW_GNU_SCANF,__MINGW_MS_PRINTF,__MINGW_MS_SCANF,__REDIRECT,
    \\__REDIRECT_NTH,__acrt_iob_func,__asprintf,__builtin_va_end,
    \\__builtin_va_start,__deprecated_msg,__fbufsize,__flbf,__fpending,
    \\__fpurge,__freadable,__freadahead,__freading,__freadptr,
    \\__freadptrinc,__fseterr,__fsetlocking,__fwritable,__fwriting,
    \\__getdelim,__gets_chk,__iob_func,__isoc23_fscanf,__isoc23_scanf,
    \\__isoc23_sscanf,__isoc23_vfscanf,__isoc23_vscanf,__isoc23_vsscanf,
    \\__isoc99_fscanf,__isoc99_scanf,__isoc99_sscanf,__isoc99_vfscanf,
    \\__isoc99_vscanf,__isoc99_vsscanf,__isthreaded,
    \\__local_stdio_printf_options,__local_stdio_scanf_options,
    \\__mingw_asprintf,__mingw_call_fgets,__mingw_call_fread,
    \\__mingw_call_gets_warn,__mingw_call_ms_sprintf,
    \\__mingw_call_ms_vsprintf,__mingw_call_snprintf,
    \\__mingw_call_sprintf,__mingw_call_tmpnam,__mingw_call_vsnprintf,
    \\__mingw_call_vsprintf,__mingw_fprintf,__mingw_fscanf,
    \\__mingw_fwprintf,__mingw_fwscanf,__mingw_get_crt_info,
    \\__mingw_printf,__mingw_scanf,__mingw_snprintf,__mingw_snwprintf,
    \\__mingw_sprintf,__mingw_sscanf,__mingw_str_free,
    \\__mingw_str_utf8_wide,__mingw_str_wide_utf8,__mingw_swprintf,
    \\__mingw_swscanf,__mingw_vasprintf,__mingw_vfprintf,__mingw_vfscanf,
    \\__mingw_vfwprintf,__mingw_vfwscanf,__mingw_vprintf,__mingw_vscanf,
    \\__mingw_vsnprintf,__mingw_vsnwprintf,__mingw_vsprintf,
    \\__mingw_vsscanf,__mingw_vswprintf,__mingw_vswscanf,
    \\__mingw_vwprintf,__mingw_vwscanf,__mingw_wprintf,__mingw_wscanf,
    \\__ms_fprintf,__ms_fscanf,__ms_fwprintf,__ms_fwscanf,__ms_printf,
    \\__ms_scanf,__ms_snprintf,__ms_snwprintf,__ms_sprintf,__ms_sscanf,
    \\__ms_swprintf,__ms_swscanf,__ms_vfprintf,__ms_vfscanf,
    \\__ms_vfwprintf,__ms_vfwscanf,__ms_vprintf,__ms_vscanf,
    \\__ms_vsnprintf,__ms_vsnwprintf,__ms_vsprintf,__ms_vsscanf,
    \\__ms_vswprintf,__ms_vswscanf,__ms_vwprintf,__ms_vwscanf,
    \\__ms_wprintf,__ms_wscanf,__overflow,__prefetch,__sF,__snprintf_chk,
    \\__sprintf_chk,__srget,__stderrp,__stdinp,__stdio_common_vfprintf,
    \\__stdio_common_vfprintf_p,__stdio_common_vfprintf_s,
    \\__stdio_common_vfscanf,__stdio_common_vfwprintf,
    \\__stdio_common_vfwprintf_s,__stdio_common_vfwscanf,
    \\__stdio_common_vsnprintf_s,__stdio_common_vsnwprintf_s,
    \\__stdio_common_vsprintf,__stdio_common_vsprintf_p,
    \\__stdio_common_vsprintf_s,__stdio_common_vsscanf,
    \\__stdio_common_vswprintf,__stdio_common_vswprintf_s,
    \\__stdio_common_vswscanf,__stdoutp,__svfscanf,__swbuf,__uflow,
    \\__vsnprintf_chk,__vsprintf_chk,__wasi_args_get,
    \\__wasi_args_sizes_get,__wasi_clock_res_get,__wasi_clock_time_get,
    \\__wasi_environ_get,__wasi_environ_sizes_get,__wasi_fd_advise,
    \\__wasi_fd_allocate,__wasi_fd_close,__wasi_fd_datasync,
    \\__wasi_fd_fdstat_get,__wasi_fd_fdstat_set_flags,
    \\__wasi_fd_fdstat_set_rights,__wasi_fd_filestat_get,
    \\__wasi_fd_filestat_set_size,__wasi_fd_filestat_set_times,
    \\__wasi_fd_pread,__wasi_fd_prestat_dir_name,__wasi_fd_prestat_get,
    \\__wasi_fd_pwrite,__wasi_fd_read,__wasi_fd_readdir,
    \\__wasi_fd_renumber,__wasi_fd_seek,__wasi_fd_sync,__wasi_fd_tell,
    \\__wasi_fd_write,__wasi_path_create_directory,
    \\__wasi_path_filestat_get,__wasi_path_filestat_set_times,
    \\__wasi_path_link,__wasi_path_open,__wasi_path_readlink,
    \\__wasi_path_remove_directory,__wasi_path_rename,
    \\__wasi_path_symlink,__wasi_path_unlink_file,__wasi_poll_oneoff,
    \\__wasi_proc_exit,__wasi_random_get,__wasi_sched_yield,
    \\__wasi_sock_accept,__wasi_sock_recv,__wasi_sock_send,
    \\__wasi_sock_shutdown,_fclose_nolock,_fcloseall,_fdopen,
    \\_fflush_nolock,_fgetc_nolock,_fgetchar,_fgetwc_nolock,_fgetwchar,
    \\_filbuf,_fileno,_flsbuf,_flushall,_fprintf_l,_fprintf_p,
    \\_fprintf_p_l,_fprintf_s_l,_fputc_nolock,_fputchar,_fputwc_nolock,
    \\_fputwchar,_fread_nolock,_fread_nolock_s,_fscanf_l,_fscanf_s_l,
    \\_fseek_nolock,_fseeki64,_fseeki64_nolock,_fsopen,_ftell_nolock,
    \\_ftelli64,_ftelli64_nolock,_fwprintf_s_l,_fwrite_nolock,
    \\_fwscanf_s_l,_get_output_format,_get_printf_count_output,
    \\_getc_nolock,_getmaxstdio,_getw,_getws,_getws_s,_lock_file,_pclose,
    \\_popen,_printf_l,_printf_p,_printf_p_l,_printf_s_l,_putc_nolock,
    \\_putw,_putws,_rmtmp,_scanf_l,_scanf_s_l,_scprintf,_scprintf_l,
    \\_scprintf_p,_scprintf_p_l,_scwprintf,_set_output_format,
    \\_set_printf_count_output,_setmaxstdio,_snprintf,_snprintf_c,
    \\_snprintf_c_l,_snprintf_l,_snprintf_s,_snprintf_s_l,_snscanf,
    \\_snscanf_l,_snscanf_s,_snscanf_s_l,_snwprintf,_snwprintf_s,
    \\_snwprintf_s_l,_snwscanf,_snwscanf_s,_snwscanf_s_l,_spawnv,
    \\_spawnve,_spawnvp,_spawnvpe,_sprintf_l,_sprintf_p,_sprintf_p_l,
    \\_sprintf_s_l,_sscanf_l,_sscanf_s_l,_swprintf,_swprintf_c,
    \\_swprintf_s_l,_swscanf_s_l,_tempnam,_ungetc_nolock,_ungetwc_nolock,
    \\_unlink,_unlock_file,_vscprintf,_vscwprintf,_vsnprintf,_vsnwprintf,
    \\_vswprintf,_vswprintf_c,_wfdopen,_wfopen,_wfopen_s,_wfreopen,
    \\_wfreopen_s,_wfsopen,_wperror,_wpopen,_wprintf_s_l,_wremove,
    \\_wscanf_s_l,_wspawnl,_wspawnle,_wspawnlp,_wspawnlpe,_wspawnv,
    \\_wspawnve,_wspawnvp,_wspawnvpe,_wtempnam,_wtmpnam,_wtmpnam_s,
    \\asprintf,asprintf_l,clearerr,clearerr_s,clearerr_unlocked,ctermid,
    \\ctermid_r,cuserid,dprintf,dprintf_l,fclose,fcloseall,fdclose,
    \\fdopen,feof,feof_unlocked,ferror,ferror_unlocked,fflush,
    \\fflush_unlocked,fgetc,fgetc_unlocked,fgetchar,fgetln,fgetpos,
    \\fgetpos64,fgets,fgets_unlocked,fgetwc,fgetws,fileno,
    \\fileno_unlocked,flockfile,flushall,fmemopen,fmtcheck,fopen,fopen64,
    \\fopen_s,fopencookie,fparseln,fprintf,fprintf_l,fprintf_s,fpurge,
    \\fputc,fputc_unlocked,fputchar,fputs,fputs_unlocked,fputwc,fputws,
    \\fread,fread_s,fread_unlocked,freopen,freopen64,freopen_s,fscanf,
    \\fscanf_l,fscanf_s,fseek,fseeko,fseeko64,fsetpos,fsetpos64,ftell,
    \\ftello,ftello64,ftruncate,ftrylockfile,funlockfile,funopen,
    \\funopen2,fwprintf,fwprintf_s,fwrite,fwrite_unlocked,fwscanf,
    \\fwscanf_s,getc,getc_unlocked,getchar,getchar_unlocked,getdelim,
    \\getline,gets,gets_s,getw,getwc,getwchar,lseek,mmap,obstack_printf,
    \\obstack_vprintf,open_memstream,open_wmemstream,pclose,perror,popen,
    \\popenve,printf,printf_l,printf_s,putc,putc_unlocked,putchar,
    \\putchar_unlocked,puts,putw,putwc,putwchar,remove,rename,renameat,
    \\renameat2,renameatx_np,renamex_np,rewind,rmtmp,scanf,scanf_l,
    \\scanf_s,setbuf,setbuffer,setlinebuf,setvbuf,snprintf,snprintf_l,
    \\snprintf_ss,snwprintf,sprintf,sprintf_l,sprintf_s,sscanf,sscanf_l,
    \\sscanf_s,stderr,stdin,stdout,swprintf,swprintf_s,swscanf,swscanf_s,
    \\sys_nerr,tempnam,tmpfile,tmpfile64,tmpfile_s,tmpnam,tmpnam_r,
    \\tmpnam_s,truncate,ungetc,ungetwc,unlink,vasprintf,vasprintf_l,
    \\vdprintf,vdprintf_l,vfprintf,vfprintf_l,vfscanf,vfscanf_l,
    \\vfwprintf,vfwscanf,vprintf,vprintf_l,vscanf,vscanf_l,vsnprintf,
    \\vsnprintf_l,vsnprintf_ss,vsnwprintf,vsprintf,vsprintf_l,vsscanf,
    \\vsscanf_l,vswprintf,vswscanf,vwprintf,vwscanf,wprintf,wprintf_s,
    \\wscanf,wscanf_s,
    \\__asprintf_chk,__dprintf_chk,__fgets_alias,__fgets_chk,__fgets_chk_warn,
    \\__fgets_unlocked_alias,__fgets_unlocked_chk,__fgets_unlocked_chk_warn,
    \\__fprintf_chk,__fread_alias,__fread_chk,__fread_chk_warn,__fread_unlocked_alias,
    \\__fread_unlocked_chk,__fread_unlocked_chk_warn,__gets_warn,__obstack_printf_chk,
    \\__obstack_vprintf_chk,__printf_chk,__vasprintf_chk,__vdprintf_chk,
    \\__vfprintf_chk,__vprintf_chk
;

/// `lua_setlevel` is declared in `src/lua.h:300` but has no definition, so providers may omit it.
const provider_optional = "lua_setlevel";

/// No LuaJIT provider symbols are excluded; only `libc_noise` stays direct.
const provider_excluded = "";

/// Creates the loader core; linked builds use its public load types.
/// Runtime builds share the dispatch's instance to preserve type identity.
pub fn createCoreModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("runtime/loader.zig"),
        .target = target,
        .optimize = optimize,
        // The Unix loader calls `dlopen`, which requires libc.
        .link_libc = true,
    });
}

/// Creates the runtime-loaded `c` module from this target's translation.
/// The generator uses the same target configuration as the translated headers.
pub fn createModule(
    b: *std.Build,
    translate: *std.Build.Step.TranslateC,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
) *std.Build.Module {
    const core = createCoreModule(b, target, optimize);

    const library = b.createModule(.{
        .root_source_file = b.path("runtime/library.zig"),
        .target = target,
        .optimize = optimize,
    });
    library.addImport("rt", core);

    return createDispatchModule(b, translate, target, optimize, core, library);
}

const GeneratedSources = struct {
    native: std.Build.LazyPath,
    dispatch: std.Build.LazyPath,
};

fn createDispatchModule(
    b: *std.Build,
    translate: *std.Build.Step.TranslateC,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    core: *std.Build.Module,
    library: *std.Build.Module,
) *std.Build.Module {
    const sources = generateDispatch(b, translate, target);

    const dispatch = b.createModule(.{
        .root_source_file = sources.dispatch,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    dispatch.addImport("rt", core);
    dispatch.addImport("library", library);
    // Use the patched translation as `c_native` so nested declarations resolve routed calls.
    // Re-export types from `c_native` to preserve their translated nominal identity.
    const native = b.createModule(.{
        .root_source_file = sources.native,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    native.addImport("c_routed", dispatch);
    dispatch.addImport("c_native", native);
    dispatch.addCSourceFiles(.{
        .files = &.{"runtime/sync.c"},
        .flags = &.{b.fmt("-DRT_SYNC_PREFIX={s}", .{sync_prefix})},
        .language = .c,
    });
    return dispatch;
}

/// Builds a host generator that reads the target translation and emits dispatch modules.
/// It runs in Debug mode; target optimization applies to the generated dispatch.
fn generateDispatch(
    b: *std.Build,
    translate: *std.Build.Step.TranslateC,
    target: std.Build.ResolvedTarget,
) GeneratedSources {
    const generator = b.addExecutable(.{
        .name = b.fmt("luajit-runtime-generate-{s}", .{
            target.result.zigTriple(b.allocator) catch @panic("unspellable target"),
        }),
        .root_module = b.createModule(.{
            .root_source_file = b.path("runtime/generate.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });

    const run = b.addRunArtifact(generator);
    run.addArg("--library");
    run.addArg("luajit");
    run.addArg("--translate");
    run.addFileArg2(translate.getOutput(), .{});
    if (libc_noise.len != 0) {
        run.addArg("--noise");
        run.addArg(libc_noise);
    }
    if (provider_optional.len != 0) {
        run.addArg("--optional");
        run.addArg(provider_optional);
    }
    if (provider_excluded.len != 0) {
        run.addArg("--exclude");
        run.addArg(provider_excluded);
    }
    run.addArg("--native-output");
    const native_source = run.addOutputFileArg2("native.zig", .{});
    run.addArg("--output");
    const dispatch_source = run.addOutputFileArg2("dispatch.zig", .{});
    return .{ .native = native_source, .dispatch = dispatch_source };
}
