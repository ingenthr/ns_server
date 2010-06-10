% Copyright (c) 2009, NorthScale, Inc.
% All rights reserved.

-module(mc_client_binary).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-export([auth/2, auth/4, create_bucket/3, delete_bucket/2,
         list_buckets/1, select_bucket/2, set_vbucket_state/3,
         stats/1, stats/2]).

%% A memcached client that speaks binary protocol.

cmd(send_list, Sock, RecvCallback, CBData, HEList) ->
    send_list(Sock, RecvCallback, CBData, HEList, undefined);

cmd(Opcode, Sock, RecvCallback, CBData, HE) ->
    case is_quiet(Opcode) of
        true  -> cmd_binary_quiet(Opcode, Sock, RecvCallback, CBData, HE);
        false -> cmd_binary_vocal(Opcode, Sock, RecvCallback, CBData, HE)
    end.

cmd_binary_quiet(Opcode, Sock, _RecvCallback, _CBData, {Header, Entry}) ->
    ok = mc_binary:send(Sock, req,
              Header#mc_header{opcode = Opcode}, ext(Opcode, Entry)),
    {ok, quiet}.

cmd_binary_vocal(?STAT = Opcode, Sock, RecvCallback, CBData,
                 {Header, Entry}) ->
    ok = mc_binary:send(Sock, req, Header#mc_header{opcode = Opcode}, Entry),
    stats_recv(Sock, RecvCallback, CBData);

cmd_binary_vocal(Opcode, Sock, RecvCallback, CBData, {Header, Entry}) ->
    ok = mc_binary:send(Sock, req,
              Header#mc_header{opcode = Opcode}, ext(Opcode, Entry)),
    cmd_binary_vocal_recv(Opcode, Sock, RecvCallback, CBData).

cmd_binary_vocal_recv(Opcode, Sock, RecvCallback, CBData) ->
    {ok, RecvHeader, RecvEntry} = mc_binary:recv(Sock, res),
    NCB = case is_function(RecvCallback) of
              true  -> RecvCallback(RecvHeader, RecvEntry, CBData);
              false -> CBData
          end,
    case Opcode =:= RecvHeader#mc_header.opcode of
        true  -> {ok, RecvHeader, RecvEntry, NCB};
        false -> cmd_binary_vocal_recv(Opcode, Sock, RecvCallback, NCB)
    end.

% -------------------------------------------------

stats_recv(Sock, RecvCallback, State) ->
    {ok, #mc_header{opcode = ROpcode,
                    keylen = RKeyLen} = RecvHeader, RecvEntry} = mc_binary:recv(Sock, res),
    case ?STAT =:= ROpcode andalso 0 =:= RKeyLen of
        true  -> {ok, RecvHeader, RecvEntry, State};
        false -> NCB = case is_function(RecvCallback) of
                           true  -> RecvCallback(RecvHeader, RecvEntry, State);
                           false -> State
                       end,
                 stats_recv(Sock, RecvCallback, NCB)
    end.

% -------------------------------------------------

send_list(_Sock, _RecvCallback, _CBData, [], LastResult) -> LastResult;
send_list(Sock, RecvCallback, CBData,
          [{#mc_header{opcode = Opcode}, _E} = HE | HERest],
          _LastResult) ->
    LastResult = cmd(Opcode, Sock, RecvCallback, CBData, HE),
    send_list(Sock, RecvCallback, CBData, HERest, LastResult).

% -------------------------------------------------

auth(_Sock, undefined) -> ok;

auth(Sock, {<<"PLAIN">>, {AuthName, undefined}}) ->
    auth(Sock, {<<"PLAIN">>, {<<>>, AuthName, <<>>}});

auth(Sock, {<<"PLAIN">>, {AuthName, AuthPswd}}) ->
    auth(Sock, {<<"PLAIN">>, {<<>>, AuthName, AuthPswd}});

auth(Sock, {<<"PLAIN">>, {ForName, AuthName, undefined}}) ->
    auth(Sock, {<<"PLAIN">>, {ForName, AuthName, <<>>}});

auth(Sock, {<<"PLAIN">>, {ForName, AuthName, AuthPswd}}) ->
    case auth(Sock, {<<"PLAIN">>, {ForName, AuthName, AuthPswd}},
              undefined, undefined) of
        {ok, _, _, _} -> ok;
        Error         -> Error
    end;

auth(_Sock, _UnknownMech) ->
    {error, emech_unsupported}.

auth(Sock, {<<"PLAIN">>, {ForName, AuthName, AuthPswd}}, CBFun, CBData) ->
    BinForName  = mc_binary:bin(ForName),
    BinAuthName = mc_binary:bin(AuthName),
    BinAuthPswd = mc_binary:bin(AuthPswd),
    case cmd(?CMD_SASL_AUTH, Sock, CBFun, CBData,
             {#mc_header{},
              #mc_entry{key = <<"PLAIN">>,
                        data = <<BinForName/binary, 0:8,
                                 BinAuthName/binary, 0:8,
                                 BinAuthPswd/binary>>
                       }}) of

        {ok, H, E, NCBData} ->
            case H#mc_header.status == ?SUCCESS of
                true  -> {ok, H, E, NCBData};
                false -> {error, eauth_status, H#mc_header.status, NCBData}
            end;
        _Error -> {error, eauth_cmd}
    end;

auth(_Sock, _UnknownMech, _CBFun, _CBData) ->
    {error, emech_unsupported}.

% -------------------------------------------------

create_bucket(Sock, BucketName, Config) ->
    case cmd(?CMD_CREATE_BUCKET, Sock, undefined, undefined,
             {#mc_header{},
              #mc_entry{key = BucketName, data = Config}}) of
        {ok, #mc_header{status=?SUCCESS}, _ME, _NCB} ->
            ok;
        Response -> process_error_response(Response)
    end.

delete_bucket(Sock, BucketName) ->
    case cmd(?CMD_DELETE_BUCKET, Sock, undefined, undefined,
             {#mc_header{},
              #mc_entry{key = BucketName}}) of
        {ok, #mc_header{status=?SUCCESS}, _ME, _NCB} ->
            ok;
        Response -> process_error_response(Response)
    end.

list_buckets(Sock) ->
    case cmd(?CMD_LIST_BUCKETS, Sock, undefined, undefined,
             {#mc_header{},
              #mc_entry{}}) of
        {ok, #mc_header{status=?SUCCESS}, #mc_entry{data=BucketsBin}, _NCB} ->
            case BucketsBin of
                undefined -> {ok, []};
                _ -> {ok, string:tokens(binary_to_list(BucketsBin), " ")}
            end;
        Response -> process_error_response(Response)
    end.

select_bucket(Sock, BucketName) ->
    case cmd(?CMD_SELECT_BUCKET, Sock, undefined, undefined,
             {#mc_header{},
              #mc_entry{key = BucketName}}) of
        {ok, #mc_header{status=?SUCCESS}, _ME, _NCB} ->
            ok;
        Response -> process_error_response(Response)
    end.

set_vbucket_state(Sock, VBucket, VBucketState) ->
    case cmd(?CMD_SET_VBUCKET_STATE, Sock, undefined, undefined,
             {#mc_header{},
              #mc_entry{key = list_to_binary(integer_to_list(VBucket)),
                        data = list_to_binary(VBucketState)}}) of
        {ok, #mc_header{status=?SUCCESS}, _ME, _NCB} ->
            ok;
        Response -> process_error_response(Response)
    end.

stats(Sock) ->
    stats(Sock, "").

stats(Sock, Key) ->
    case cmd(?STAT, Sock,
             fun (_MH, ME, CD) ->
                     [[binary_to_list(ME#mc_entry.key),
                       binary_to_list(ME#mc_entry.data)] | CD]
             end,
             [],
             {#mc_header{}, #mc_entry{key=list_to_binary(Key)}}) of
        {ok, #mc_header{status=?SUCCESS}, _E, Stats} ->
            {ok, Stats};
        Response -> process_error_response(Response)
    end.


%% -------------------------------------------------

is_quiet(?GETQ)       -> true;
is_quiet(?GETKQ)      -> true;
is_quiet(?SETQ)       -> true;
is_quiet(?ADDQ)       -> true;
is_quiet(?REPLACEQ)   -> true;
is_quiet(?DELETEQ)    -> true;
is_quiet(?INCREMENTQ) -> true;
is_quiet(?DECREMENTQ) -> true;
is_quiet(?QUITQ)      -> true;
is_quiet(?FLUSHQ)     -> true;
is_quiet(?APPENDQ)    -> true;
is_quiet(?PREPENDQ)   -> true;
is_quiet(?RSETQ)      -> true;
is_quiet(?RAPPENDQ)   -> true;
is_quiet(?RPREPENDQ)  -> true;
is_quiet(?RDELETEQ)   -> true;
is_quiet(?RINCRQ)     -> true;
is_quiet(?RDECRQ)     -> true;
is_quiet(_)           -> false.

ext(?SET,        Entry) -> ext_flag_expire(Entry);
ext(?SETQ,       Entry) -> ext_flag_expire(Entry);
ext(?ADD,        Entry) -> ext_flag_expire(Entry);
ext(?ADDQ,       Entry) -> ext_flag_expire(Entry);
ext(?REPLACE,    Entry) -> ext_flag_expire(Entry);
ext(?REPLACEQ,   Entry) -> ext_flag_expire(Entry);
ext(?INCREMENT,  Entry) -> ext_arith(Entry);
ext(?INCREMENTQ, Entry) -> ext_arith(Entry);
ext(?DECREMENT,  Entry) -> ext_arith(Entry);
ext(?DECREMENTQ, Entry) -> ext_arith(Entry);
ext(_, Entry) -> Entry.

ext_flag_expire(#mc_entry{ext = Ext, flag = Flag, expire = Expire} = Entry) ->
    case Ext of
        undefined -> Entry#mc_entry{ext = <<Flag:32, Expire:32>>};
        _         -> Entry
    end.

ext_arith(#mc_entry{ext = Ext, data = Data, expire = Expire} = Entry) ->
    case Ext of
        undefined ->
            Ext2 = case Data of
                       <<>>      -> <<1:64, 0:64, Expire:32>>;
                       undefined -> <<1:64, 0:64, Expire:32>>;
                       _         -> <<Data:64, 0:64, Expire:32>>
                   end,
            Entry#mc_entry{ext = Ext2, data = undefined};
        _ -> Entry
    end.

map_status(?SUCCESS) ->
    mc_status_success;
map_status(?KEY_ENOENT) ->
    mc_status_key_enoent;
map_status(?KEY_EEXISTS) ->
    mc_status_key_eexists;
map_status(?E2BIG) ->
    mc_status_e2big;
map_status(?EINVAL) ->
    mc_status_einval;
map_status(?NOT_STORED) ->
    mc_status_not_stored;
map_status(?DELTA_BADVAL) ->
    mc_status_delta_badval;
map_status(?UNKNOWN_COMMAND) ->
    mc_status_unknown_command;
map_status(?ENOMEM) ->
    mc_status_enomem.

process_error_response({ok, #mc_header{status=Status}, #mc_entry{data=Data}, _NCB}) ->
    {memcached_error, map_status(Status), binary_to_list(Data)};
process_error_response(Error) ->
    {client_error, Error}.

% -------------------------------------------------

blank_he() ->
    {#mc_header{}, #mc_entry{}}.

noop_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    {ok, _H, _E, undefined} = cmd(?NOOP, Sock, undefined, undefined, blank_he()),
    ok = gen_tcp:close(Sock).

flush_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    flush_test_sock(Sock),
    ok = gen_tcp:close(Sock).

flush_test_sock(Sock) ->
    {ok, _H, _E, undefined} = cmd(?FLUSH, Sock, undefined, undefined, blank_he()).

set_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    set_test_sock(Sock, <<"aaa">>),
    ok = gen_tcp:close(Sock).

set_test_sock(Sock, Key) ->
    flush_test_sock(Sock),
    (fun () ->
        {ok, _H, _E, undefined} = cmd(?SET, Sock, undefined, undefined,
                                      {#mc_header{},
                                       #mc_entry{key = Key, data = <<"AAA">>}}),
        get_test_match(Sock, Key, <<"AAA">>)
    end)().

get_test_match(Sock, Key, Data) ->
    D = ets:new(test, [set]),
    ets:insert(D, {nvals, 0}),
    {ok, _H, E, _S} = cmd(?GETK, Sock,
                      fun (_H, E, _S) ->
                              ets:update_counter(D, nvals, 1),
                              ?assertMatch(Key, E#mc_entry.key),
                              ?assertMatch(Data, E#mc_entry.data)
                      end, undefined,
                      {#mc_header{}, #mc_entry{key = Key}}),
    ?assertMatch(Key, E#mc_entry.key),
    ?assertMatch(Data, E#mc_entry.data),
    ?assertMatch([{nvals, 1}], ets:lookup(D, nvals)).

get_miss_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    flush_test_sock(Sock),
    {ok, H, _E, ok} = cmd(?GET, Sock, fun (_H, _E, _CD) -> ok end, undefined,
                          {#mc_header{}, #mc_entry{key = <<"not_a_key">>}}),
    ?assert(H#mc_header.status =/= ?SUCCESS),
    ok = gen_tcp:close(Sock).

getk_miss_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    flush_test_sock(Sock),
    {ok, H, _E, ok} = cmd(?GETK, Sock, fun (_H, _E, undefined) -> ok end, undefined,
                          {#mc_header{}, #mc_entry{key = <<"not_a_key">>}}),
    ?assert(H#mc_header.status =/= ?SUCCESS),
    ok = gen_tcp:close(Sock).

arith_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    flush_test_sock(Sock),
    Key = <<"a">>,
    (fun () ->
        {ok, _H, _E, undefined} = cmd(?SET, Sock, undefined, undefined,
                           {#mc_header{},
                            #mc_entry{key = Key, data = <<"1">>}}),
        get_test_match(Sock, Key, <<"1">>),
        ok
    end)(),
    (fun () ->
        {ok, _H, _E, undefined} = cmd(?INCREMENT, Sock, undefined, undefined,
                           {#mc_header{},
                            #mc_entry{key = Key, data = 1}}),
        get_test_match(Sock, Key, <<"2">>),
        ok
    end)(),
    (fun () ->
        {ok, _H, _E, undefined} = cmd(?INCREMENT, Sock, undefined, undefined,
                           {#mc_header{},
                            #mc_entry{key = Key, data = 1}}),
        get_test_match(Sock, Key, <<"3">>),
        ok
    end)(),
    (fun () ->
        {ok, _H, _E, undefined} = cmd(?INCREMENT, Sock, undefined, undefined,
                           {#mc_header{},
                            #mc_entry{key = Key, data = 10}}),
        get_test_match(Sock, Key, <<"13">>),
        ok
    end)(),
    (fun () ->
        {ok, _H, _E, undefined} = cmd(?DECREMENT, Sock, undefined, undefined,
                           {#mc_header{},
                            #mc_entry{key = Key, data = 1}}),
        get_test_match(Sock, Key, <<"12">>),
        ok
    end)(),
    ok = gen_tcp:close(Sock).

stats_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    D = ets:new(test, [set]),
    ets:insert(D, {nvals, 0}),
    {ok, _H, _E, _C} = cmd(?STAT, Sock,
                                  fun (_MH, _ME, _CD) ->
                                          ets:update_counter(D, nvals, 1)
                                  end, undefined,
                                  {#mc_header{}, #mc_entry{}}),
    [{nvals, X}] = ets:lookup(D, nvals),
    ?assert(X > 0),
    ok = gen_tcp:close(Sock).

second_stats_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    {ok, _H, _E, Stats} = cmd(?STAT, Sock,
                              fun (_MH, ME, CD) ->
                                      dict:store(ME#mc_entry.key,
                                                 ME#mc_entry.data,
                                                 CD)
                              end,
                              dict:new(),
                              {#mc_header{}, #mc_entry{}}),
    ?assert(dict:size(Stats) > 0),
    ok = gen_tcp:close(Sock).

stats_subcommand_test() ->
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    {ok, _H, _E, Stats} = cmd(?STAT, Sock,
                              fun (_MH, ME, CD) ->
                                      dict:store(ME#mc_entry.key,
                                                 ME#mc_entry.data,
                                                 CD)
                              end,
                              dict:new(),
                              {#mc_header{}, #mc_entry{key = <<"settings">>}}),
    ?assert(dict:size(Stats) > 0),
    ok = gen_tcp:close(Sock).
