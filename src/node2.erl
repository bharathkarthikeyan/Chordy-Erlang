-module(node2).
-export([start/1, start/2]).

-define(Stabilize, 1000).
-define(Timeout, 10000).

start(Id) ->
    start(Id, nil).

start(Id, Peer) ->
    timer:start(),
    spawn(fun() -> init(Id, Peer) end).

init(Id, Peer) ->
    Predecessor = nil,
    {ok, Successor} = connect(Id, Peer),
    schedule_stabilize(),
    node(Id, Predecessor, Successor, []).

connect(Id, nil) ->
    {ok, {Id, self()}};

connect(_, Peer) ->
    Qref = make_ref(),
    Peer ! {key, Qref, self()},
    receive
	{Qref, Skey} ->
	    {ok, {Skey, Peer}}
    after ?Timeout ->
	    io:format("Time out: no response~n", [])
    end.




node(Id, Predecessor, Successor, Store) ->
    receive
	% A peer needs to know our key Id
	{key, Qref, Peer} ->
	    Peer ! {Qref, Id},
	    node(Id, Predecessor, Successor, Store);
	% New node
	{notify, New} ->
	    Pred = notify(New, Id, Predecessor),
	    node(Id, Pred, Successor, Store);
	% Message coming from the predecessor who wants to know our predecessor
	{request, Peer} ->
	    request(Peer, Predecessor),
	    node(Id, Predecessor, Successor, Store);
	% What is the predecessor of the next node (successor)
	{status, Pred} ->
	    Succ = stabilize(Pred, Id, Successor),
	    node(Id, Predecessor, Succ, Store);
	stabilize ->
	    stabilize(Successor),
	    node(Id, Predecessor, Successor, Store);
	probe ->
	    create_probe(Id, Successor),
	    node(Id, Predecessor, Successor, Store);
	{probe, Id, Nodes, T} ->
	    remove_probe(T, Nodes),
	    node(Id, Predecessor, Successor, Store);
	{probe, Ref, Nodes, T} ->
	    forward_probe(Ref, T, Nodes, Id, Successor),
	    node(Id, Predecessor, Successor, Store);
	{add, Key, Value, Qref, Client} ->
	    Added = add(Key, Value, Qref, Client,
			Id, Predecessor, Successor, Store),
	    node(Id, Predecessor, Successor, Added);
	{lookup, Key, Qref, Client} ->
	    lookup(Key, Qref, Client, Id, Predecessor, Successor, Store),
	    node(Id, Predecessor, Successor, Store);
	state ->
	    io:format(' Id : ~w~n Predecessor : ~w~n Successor : ~w~n', [Id, Predecessor, Successor]),
	    node(Id, Predecessor, Successor);
	stop -> ok;
	_ ->
	    io:format('Strange message received'),
	    node(Id, Predecessor, Successor)
    end.

stabilize({_, Spid}) ->
    Spid ! {request, self()}.

% Pred = Successor current predecessor
% Id = Id of the current node
% Successor = Successor of the current node
stabilize(Pred, Id, Successor) ->
    {Skey, Spid} = Successor,
    case Pred of
	nil -> 
	    Spid ! {notify, {Id, self()}},
	    Successor;
	{Id, _} -> 
	    Successor;
	{Skey, _} -> 
	    Spid ! {notify, {Id, self()}},
	    Successor;
	{Xkey, Xpid} ->
	    case key:between(Xkey, Id, Skey) of
		true ->
		    Xpid ! {request, self()}, 
		    Pred;
		false ->
		    Spid ! {notify, {Id, self()}},
		    Successor
	    end
    end.
	    
schedule_stabilize() ->
    timer:send_interval(?Stabilize, self(), stabilize).

request(Peer, Predecessor) ->
    case Predecessor of
	nil ->
	    Peer ! {status, nil};
	{Pkey, Ppid} ->
	    Peer ! {status, {Pkey, Ppid}}
    end.

notify({Nkey, Npid}, Id, Predecessor) ->
    case Predecessor of
	nil ->
	    {Nkey, Npid};
	{Pkey, _} ->
	    case key:between(Nkey, Pkey, Id) of
		true ->
		    {Nkey, Npid};
		false ->
		    Predecessor
	    end
    end.

create_probe(Id,{_,Spid}) ->
    Spid ! {probe,Id,[Id],erlang:now()}.

remove_probe(T, Nodes) ->
    Duration = timer:now_diff(erlang:now(),T),
    Printer = fun(E) -> io:format("~p ",[E]) end,
    lists:foreach(Printer,Nodes),
    io:format("~n Time = ~p",[Duration]).

forward_probe(Ref, T, Nodes, Id, {_,Spid}) ->
    Spid ! {probe,Ref,Nodes ++ [Id],T}.


add(Key, Value, Qref, Client, Id, {Pkey, _}, {_, Spid}, Store) ->
    case Id == Client of
	true ->
	    Client ! {Qref, ok},
	    {Key, Value} | Store;
	false ->
	    Spid ! {add, Key, Value, Qref, Client},
	    Store
    end.

lookup(Key, Qref, Client, Id, {Pkey, _}, Successor, Store) ->
    case Id == Client of
	true ->
	    Result = storage:lookup(Key, Store),
	    Client ! {Qref, Result};
	false ->
	    {_, Spid} = Successor,
	    Spid ! {lookup, Key, Qref, Client}
    end.
