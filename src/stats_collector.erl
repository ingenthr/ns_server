%%%-------------------------------------------------------------------
%%% File    : stats_collector.erl
%%% Author  : Aliaksey Kandratsenka <alk@tut.by>
%%% Description : per-bucket & per-node stats collector process. Not a
%%% gen_server, because no gen_server:multicall does not suits us here.
%%%
%%%
%%% Created :  6 Jan 2010 by Aliaksey Kandratsenka <alk@tut.by>
%%%-------------------------------------------------------------------
-module(stats_collector).

-export([loop/1]).

do_grab_stat(_State) ->
    [{stat1, 1},
     {stat2, 2}].

loop(State) ->
    receive
        {grab_stats, From, Ref} ->
            From ! {grab_stats_res, Ref, self(), do_grab_stat(State)},
            loop(State)
    end.