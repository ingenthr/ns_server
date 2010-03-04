%% This is a supervisor adaptor that either:
%%  1. monitors an existing instance and crashes when it exits.
%%  2. registers itself as a global process and runs a supervisor.

-module(dist_sup_dispatch).

-export([start_link/0, init/1]).

start_link() ->
    proc_lib:start_link(?MODULE, init, [self()]).

init(Parent) ->
    process_flag(trap_exit, true),
    case do_initialization() of
        {ok, Pid} ->
            proc_lib:init_ack(Parent, {ok, self()}),
            wait(Pid);
        {error, Reason} ->
            exit(Reason)
    end.

do_initialization() ->
    monitor_or_supervise(global:whereis_name(?MODULE)).

monitor_or_supervise(undefined) ->
    yes = global:register_name(?MODULE, self()),
    error_logger:info_msg("dist_sup_dispatch: starting global singleton.~n"),
    global_singleton_supervisor:start_link();
monitor_or_supervise(Pid) when is_pid(Pid) ->
    error_logger:info_msg("dist_sup_dispatch: monitoring ~p.~n", [Pid]),
    erlang:monitor(process, Pid),
    {ok, undefined}.

wait(Pid) ->
    receive
        {'EXIT', From, _Reason} when Pid =/= undefined, From =/= Pid ->
            error_logger:info_msg("dist_sup_dispatch: Shutting down child.~n"),
            exit(Pid, shutdown),
            receive
                {'EXIT', Pid, Reason} ->
                    error_logger:info_msg("dist_sup_dispatch: Child exited with reason ~p~n",
                                          [Reason])
            end;
        LikelyExitMessage ->
            error_logger:info_msg("dist_sup_dispatch: Exiting, I got a message: ~p~n",
                                  [LikelyExitMessage])
    end.
