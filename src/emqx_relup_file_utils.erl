-module(emqx_relup_file_utils).

-export([cp_r/2]).

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
