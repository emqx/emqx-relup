-module(emqx_relup_utils).

-export([ assert_propl_get/3
        , assert_propl_get/4
        , ts_filename/1
        ]).

assert_propl_get(Key, Proplist, ErrMsg) ->
    assert_propl_get(Key, Proplist, ErrMsg, #{}).

assert_propl_get(Key, Proplist, ErrMsg, Meta) ->
    case proplists:get_value(Key, Proplist) of
        undefined ->
            throw({ErrMsg, maps:merge(#{key => Key, proplist => Proplist}, Meta)});
        Value -> Value
    end.

ts_filename(Name) ->
    {{YY,MM,DD}, {H,M,S}} = calendar:now_to_datetime(erlang:timestamp()),
    io_lib:format("~s_~4..0w-~2..0w-~2..0w_~2..0w-~2..0w-~2..0w", [Name, YY, MM, DD, H, M, S]).
