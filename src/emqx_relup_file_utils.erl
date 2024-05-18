-module(emqx_relup_file_utils).

-include_lib("kernel/include/file.hrl").

-export([cp_r/2, tmp_dir/0, ensure_dir_deleted/1, ensure_file_deleted/1]).

cp_r(Src, Dst) ->
    case filelib:is_file(Src) of
        true ->
            case filelib:is_dir(Src) of
                true ->
                    cp_r_dir(Src, Dst);
                false ->
                    case file:copy(Src, Dst) of
                        {ok, _} -> ok;
                        {error, Reason} ->
                            {error, Reason}
                    end
            end;
        false ->
            {error, {src_not_exists, Src}}
    end.

tmp_dir() ->
    case tmp_dir_1() of
        false -> throw(cannot_get_writable_tmp_dir);
        Dir -> Dir
    end.

ensure_dir_deleted(Dir) ->
    case file:del_dir_r(Dir) of
        ok -> ok;
        {error, enoent} -> ok;
        {error, Reason} ->
            throw({failed_to_delete_dir, #{dir => Dir, reason => Reason}})
    end.

ensure_file_deleted(FileName) ->
    case file:delete(FileName) of
        ok -> ok;
        {error, enoent} -> ok;
        {error, Reason} ->
            throw({failed_to_delete_file, #{file => FileName, reason => Reason}})
    end.

%%==============================================================================
%% Internal functions
%%==============================================================================
cp_r_dir(SrcDir, DstDir) ->
    case filelib:ensure_dir(filename:join([DstDir, "dummy"])) of
        ok ->
            do_cp_r_dir(filelib:wildcard(SrcDir ++ "/*"), DstDir);
        {error, Reason} ->
            {error, Reason}
    end.

do_cp_r_dir([], _) ->
    ok;
do_cp_r_dir([File | Files], DstDir) ->
    case cp_r(File, filename:join([DstDir, filename:basename(File)])) of
        ok ->
            do_cp_r_dir(Files, DstDir);
        {error, Reason} ->
            {error, Reason}
    end.

tmp_dir_1() ->
    case get_writable_tmp_dir(["TMPDIR", "TEMP", "TMP"]) of
        false ->
            case writable_tmp_dir("/tmp") of
                false ->
                    {ok, Dir} = file:get_cwd(),
                    writable_tmp_dir(Dir);
                Tmp -> Tmp
            end;
        Tmp -> Tmp
    end.

get_writable_tmp_dir([Env | Envs]) ->
    case writable_env_tmp_dir(Env) of
        false -> get_writable_tmp_dir(Envs);
        Tmp -> Tmp
    end;
get_writable_tmp_dir([]) ->
    false.

writable_env_tmp_dir(Env) ->
    case os:getenv(Env) of
      false -> false;
      Tmp -> writable_tmp_dir(Tmp)
    end.

writable_tmp_dir(Tmp) ->
    case file:read_file_info(Tmp) of
        {ok, Info} ->
            case Info#file_info.access of
                write -> Tmp;
                read_write -> Tmp;
                _ -> false
            end;
        {error, _} -> false
    end.
