-module(h2_stream_set).
-include("http2.hrl").
-include_lib("stdlib/include/ms_transform.hrl").
%-compile([export_all]).

%% This module exists to manage a set of all streams for a given
%% connection. When a connection starts, a stream set logically
%% contains streams from id 1 to 2^31-1. In practicality, storing that
%% many idle streams in a collection of any type would be more memory
%% intensive. We're going to manage that here in this module, but to
%% the outside, it will behave as if they all exist

-define(RECV_WINDOW_SIZE, 1).
-define(SEND_WINDOW_SIZE, 2).
-define(SEND_LOCK, 3).
-define(SETTINGS_LOCK, 4).
-define(STREAMS_LOCK, 5).
-define(ENCODER_LOCK, 6).
-define(MY_NEXT_AVAILABLE_STREAM_ID, 7).

-define(UNLOCKED, 0).
-define(SHARED_LOCK, 1).
-define(EXCLUSIVE_LOCK, 2).

-record(
   stream_set,
   {
     %% Type determines which streams are mine, and which are theirs
     type :: client | server,

     atomics = atomics:new(7, []),

     socket :: sock:socket(),

     connection :: pid(),

     table = ets:new(?MODULE, [public, {keypos, 2}]) :: ets:tab(),
     %% Streams initiated by this peer
     %% mine :: peer_subset(),
     %% Streams initiated by the other peer
     %% theirs :: peer_subset()
     callback_mod = undefined :: atom(),
     callback_opts = [] :: list()
   }).
-type stream_set() :: #stream_set{}.
-export_type([stream_set/0]).

-record(connection_settings, {
          type :: self_settings | peer_settings,
          settings = #settings{} :: settings()
         }).

-record(context, {
          type = encode_context :: encode_context,
          context = hpack:new_context() :: hpack:context()
         }).


-record(lock, {
          id :: {lock, non_neg_integer()},
          holders = [] :: [pid()],
          waiters = [] :: [{pid(), reference()}]
         }
       ).

%% The stream_set needs to keep track of two subsets of streams, one
%% for the streams that it has initiated, and one for the streams that
%% have been initiated on the other side of the connection. It is this
%% peer_subset that will try to optimize the set of stream metadata
%% that we're storing in memory. For each side of the connection, we
%% also need an accurate count of how many are currently active

-record(
   peer_subset,
   {
     type :: mine | theirs,
     %% Provided by the connection settings, we can check against this
     %% every time we try to add a stream to this subset
     max_active = unlimited :: unlimited | pos_integer(),
     %% A counter that's an accurate reflection of the number of
     %% active streams
     active_count = 0 :: non_neg_integer(),

     %% lowest_stream_id is the lowest stream id that we're currently
     %% managing in memory. Any stream with an id lower than this is
     %% automatically of type closed.
     lowest_stream_id = 0 :: stream_id(),

     %% Next available stream id will be the stream id of the next
     %% stream that can be added to this subset. That means if asked
     %% for a stream with this id or higher, the stream type returned
     %% must be idle. Any stream id lower than this that isn't active
     %% must be of type closed.
     next_available_stream_id :: stream_id()
   }).
-type peer_subset() :: #peer_subset{}.


%% Streams all have stream_ids. It is the only thing all three types
%% have. It *MUST* be the first field in *ALL* *_stream{} records.

%% The metadata for an active stream is, unsurprisingly, the most
%% complex.
-record(
   active_stream, {
     id                    :: stream_id(),
     % Pid running the http2_stream gen_statem
     pid                   :: pid(),
     % The process to notify with events on this stream
     notify_pid            :: pid() | undefined,
     % The stream's flow control send window size
     send_window_size      :: non_neg_integer(),
     % The stream's flow control recv window size
     recv_window_size      :: non_neg_integer(),
     % Data that is in queue to send on this stream, if flow control
     % hasn't allowed it to be sent yet
     queued_data           :: undefined | done | binary(),
     % Has the body been completely recieved.
     body_complete = false :: boolean(),
     trailers = undefined  :: [h2_frame:frame()] | undefined
    }).
-type active_stream() :: #active_stream{}.

%% The closed_stream record is way more important to a client than a
%% server. It's a way of holding on to a response that has been
%% recieved, but not processed by the client yet.
-record(
   closed_stream, {
     id               :: stream_id(),
     % The pid to notify about events on this stream
     notify_pid       :: pid() | undefined,
     % The response headers received
     response_headers :: hpack:headers() | undefined,
     % The response body
     response_body    :: binary() | undefined,
     % The response trailers received
     response_trailers :: hpack:headers() | undefined,
     % Can this be thrown away?
     garbage = false  :: boolean() | undefined
     }).
-type closed_stream() :: #closed_stream{}.

%% An idle stream record isn't used for much. It's never stored,
%% unlike the other two types. It is always generated on the fly when
%% asked for a stream >= next_available_stream_id. But, we're able to
%% perform a rst_stream operation on it, and we need a stream_id to
%% make that happen.
-record(
   idle_stream, {
     id :: stream_id()
    }).
-type idle_stream() :: #idle_stream{}.

%% So a stream can be any of these things. And it will be something
%% that you can pass back into serveral functions here in this module.
-type stream() :: active_stream()
                | closed_stream()
                | idle_stream().
-export_type([stream/0]).

%% Set Operations
-export(
   [
    new/4,
    new_stream/5,
    get/2,
    upsert/2,
    take_lock/3,
    take_exclusive_lock/3,
    get_callback/1,
    socket/1,
    connection/1
   ]).

%% Accessors
-export(
   [
    queued_data/1,
    update_trailers/2,
    update_data_queue/3,
    decrement_recv_window/2,
    recv_window_size/1,
    decrement_socket_recv_window/2,
    increment_socket_recv_window/2,
    socket_recv_window_size/1,
    set_socket_recv_window_size/2,
    decrement_socket_send_window/2,
    increment_socket_send_window/2,
    socket_send_window_size/1,
    set_socket_send_window_size/2,

    response/1,
    send_window_size/1,
    increment_send_window_size/2,
    pid/1,
    stream_id/1,
    stream_pid/1,
    notify_pid/1,
    type/1,
    stream_set_type/1,
    my_active_count/1,
    their_active_count/1,
    my_active_streams/1,
    their_active_streams/1,
    my_max_active/1,
    their_max_active/1,
    get_next_available_stream_id/1,
    get_settings/1,
    update_self_settings/2,
    update_peer_settings/2,
    get_encode_context/1,
    update_encode_context/2
   ]
  ).

-export(
   [
    close/3,
    send_what_we_can/2,
    update_all_recv_windows/2,
    update_all_send_windows/2,
    update_their_max_active/2,
    update_my_max_active/2
   ]
  ).

%% new/1 returns a new stream_set. This is your constructor.
-spec new(
        client | server,
        sock:socket(),
        atom(), list()
       ) -> stream_set().
new(client, Socket, CallbackMod, CallbackOpts) ->
    StreamSet = #stream_set{
        callback_mod = CallbackMod,
        callback_opts = CallbackOpts,
        socket=Socket,
        connection=self(),
       type=client},
    ets:insert_new(StreamSet#stream_set.table, #lock{id={lock, ?SEND_LOCK}}),
    ets:insert_new(StreamSet#stream_set.table, #lock{id={lock, ?SETTINGS_LOCK}}),
    ets:insert_new(StreamSet#stream_set.table, #lock{id={lock, ?STREAMS_LOCK}}),
    ets:insert_new(StreamSet#stream_set.table, #lock{id={lock, ?ENCODER_LOCK}}),
    ets:insert_new(StreamSet#stream_set.table, #connection_settings{type=self_settings}),
    ets:insert_new(StreamSet#stream_set.table, #connection_settings{type=peer_settings}),
    ets:insert_new(StreamSet#stream_set.table, #context{}),
    atomics:put(StreamSet#stream_set.atomics, ?MY_NEXT_AVAILABLE_STREAM_ID, 1),
    %% I'm a client, so mine are always odd numbered
    ets:insert_new(StreamSet#stream_set.table,
                   #peer_subset{
                      type=mine,
                      lowest_stream_id=0,
                      next_available_stream_id=1
                     }),
    %% And theirs are always even
     ets:insert_new(StreamSet#stream_set.table, 
                    #peer_subset{
                       type=theirs,
                       lowest_stream_id=0,
                       next_available_stream_id=2
                      }),
    StreamSet;
new(server, Socket, CallbackMod, CallbackOpts) ->
    StreamSet = #stream_set{
       callback_mod = CallbackMod,
       callback_opts = CallbackOpts,
       socket=Socket,
       connection=self(),
       type=server},
    ets:insert_new(StreamSet#stream_set.table, #lock{id={lock, ?SEND_LOCK}}),
    ets:insert_new(StreamSet#stream_set.table, #lock{id={lock, ?SETTINGS_LOCK}}),
    ets:insert_new(StreamSet#stream_set.table, #lock{id={lock, ?STREAMS_LOCK}}),
    ets:insert_new(StreamSet#stream_set.table, #lock{id={lock, ?ENCODER_LOCK}}),
    ets:insert_new(StreamSet#stream_set.table, #connection_settings{type=self_settings}),
    ets:insert_new(StreamSet#stream_set.table, #connection_settings{type=peer_settings}),
    ets:insert_new(StreamSet#stream_set.table, #context{}),
    %% I'm a server, so mine are always even numbered
    atomics:put(StreamSet#stream_set.atomics, ?MY_NEXT_AVAILABLE_STREAM_ID, 2),
    ets:insert_new(StreamSet#stream_set.table,
                   #peer_subset{
                      type=mine,
                      lowest_stream_id=0,
                      next_available_stream_id=2
                     }),
    %% And theirs are always odd
     ets:insert_new(StreamSet#stream_set.table, 
                    #peer_subset{
                       type=theirs,
                       lowest_stream_id=0,
                       next_available_stream_id=1
                      }),
    StreamSet.

-spec new_stream(
        StreamId :: stream_id() | next,
        NotifyPid :: pid(),
        CBMod :: module(),
        CBOpts :: list(),
        StreamSet :: stream_set()) ->
                        {pid(), stream_id(), stream_set()}
                            | {error, error_code(), closed_stream()}.
new_stream(
          StreamId0,
          NotifyPid,
          CBMod,
          CBOpts,
          StreamSet) ->

    {SelfSettings, PeerSettings} = get_settings(StreamSet),
    InitialSendWindow = PeerSettings#settings.initial_window_size,
    InitialRecvWindow = SelfSettings#settings.initial_window_size,
    {PeerSubset, StreamId} = case StreamId0 of 
                                 next ->
                                     Next = atomics:add_get(StreamSet#stream_set.atomics, ?MY_NEXT_AVAILABLE_STREAM_ID, 2),
                                     P0 = get_my_peers(StreamSet),
                                     {P0, Next - 2};
                                 Id ->
                                     {get_peer_subset(Id, StreamSet), Id}
                             end,

    case PeerSubset#peer_subset.max_active =/= unlimited andalso
         PeerSubset#peer_subset.active_count >= PeerSubset#peer_subset.max_active
    of
        true ->
            {error, ?REFUSED_STREAM, #closed_stream{id=StreamId}};
        false ->
            {ok, Pid} = case self() == StreamSet#stream_set.connection of
                            true ->
                                h2_stream:start_link(
                                  StreamId,
                                  StreamSet,
                                  self(),
                                  CBMod,
                                  CBOpts
                                 );
                            false ->
                                h2_stream:start(
                                  StreamId,
                                  StreamSet,
                                  StreamSet#stream_set.connection,
                                  CBMod,
                                  CBOpts
                                 )
                        end,
                    NewStream = #active_stream{
                           id = StreamId,
                           pid = Pid,
                           notify_pid=NotifyPid,
                           send_window_size=InitialSendWindow,
                           recv_window_size=InitialRecvWindow
                          },
            case upsert(NewStream, StreamSet) of
                {error, ?REFUSED_STREAM} ->
                    %% This should be very rare, if it ever happens at
                    %% all. The case clause above tests the same
                    %% condition that upsert/2 checks to return this
                    %% result. Still, we need this case statement
                    %% because returning an {error tuple here would be
                    %% catastrophic

                    %% If this did happen, we need to kill this
                    %% process, or it will just hang out there.
                    h2_stream:stop(Pid),
                    {error, ?REFUSED_STREAM, #closed_stream{id=StreamId}};
                NewStreamSet ->
                    {Pid, StreamId, NewStreamSet}
            end
    end.

get_callback(#stream_set{callback_mod=CM, callback_opts = CO}) ->
    {CM, CO}.

socket(#stream_set{socket=Sock}) ->
    Sock.

connection(#stream_set{connection=Conn}) ->
    Conn.

get_settings(StreamSet) ->
    {(hd(ets:lookup(StreamSet#stream_set.table, self_settings)))#connection_settings.settings, (hd(ets:lookup(StreamSet#stream_set.table, peer_settings)))#connection_settings.settings}.

update_self_settings(StreamSet, Settings) ->
    ets:insert(StreamSet#stream_set.table, #connection_settings{type=self_settings, settings=Settings}).

update_peer_settings(StreamSet, Settings) ->
    ets:insert(StreamSet#stream_set.table, #connection_settings{type=peer_settings, settings=Settings}).

get_encode_context(StreamSet) ->
    (hd(ets:lookup(StreamSet#stream_set.table, encode_context)))#context.context.

update_encode_context(StreamSet, Context) ->
    ets:insert(StreamSet#stream_set.table, #context{type=encode_context, context=Context}).

-spec get_peer_subset(
        stream_id(),
        stream_set()) ->
                               peer_subset().
get_peer_subset(Id, StreamSet) ->
    case {Id rem 2, StreamSet#stream_set.type} of
        {0, client} ->
            get_their_peers(StreamSet);
        {1, client} ->
            get_my_peers(StreamSet);
        {0, server} ->
            get_my_peers(StreamSet);
        {1, server} ->
            get_their_peers(StreamSet)
    end.

-spec get_my_peers(stream_set()) -> peer_subset().
get_my_peers(StreamSet) ->
    Next = atomics:get(StreamSet#stream_set.atomics, ?MY_NEXT_AVAILABLE_STREAM_ID),
   (hd(ets:lookup(StreamSet#stream_set.table, mine)))#peer_subset{next_available_stream_id=Next}.

-spec get_their_peers(stream_set()) -> peer_subset().
get_their_peers(StreamSet) ->
    hd(ets:lookup(StreamSet#stream_set.table, theirs)).

set_my_peers(StreamSet, Peers) ->
    ets:insert(StreamSet#stream_set.table, Peers).

set_their_peers(StreamSet, Peers) ->
    ets:insert(StreamSet#stream_set.table, Peers).

get_my_active_streams(StreamSet) ->
    case StreamSet#stream_set.type of
        client ->
            ets:select(StreamSet#stream_set.table, ets:fun2ms(fun(S=#active_stream{id=Id}) when Id rem 2 == 1 ->
                                                                      S
                                                              end));
        server ->
            ets:select(StreamSet#stream_set.table, ets:fun2ms(fun(S=#active_stream{id=Id}) when Id rem 2 == 0 ->
                                                                      S
                                                              end))
    end.

get_their_active_streams(StreamSet) ->
    case StreamSet#stream_set.type of
        client ->
            ets:select(StreamSet#stream_set.table, ets:fun2ms(fun(S=#active_stream{id=Id}) when Id rem 2 == 0 ->
                                                                      S
                                                              end));
        server ->
            ets:select(StreamSet#stream_set.table, ets:fun2ms(fun(S=#active_stream{id=Id}) when Id rem 2 == 1 ->
                                                                      S
                                                              end))
    end.

-spec set_peer_subset(
        Id :: stream_id(),
        StreamSet :: stream_set(),
        NewPeerSubset :: peer_subset()
                         ) ->
                             stream_set().
set_peer_subset(_Id, StreamSet, NewPeerSubset) ->
    ets:insert(StreamSet#stream_set.table, NewPeerSubset),
    StreamSet.

%% get/2 gets a stream. The logic in here basically just chooses which
%% subset.
-spec get(Id :: stream_id(),
          Streams :: stream_set()) ->
                 stream().
get(Id, StreamSet) ->
    get_from_subset(Id,
                    get_peer_subset(
                      Id,
                      StreamSet), StreamSet).


-spec get_from_subset(
        Id :: stream_id(),
        PeerSubset :: peer_subset(),
        StreamSet :: stream_set())
                     ->
    stream().
get_from_subset(Id,
                #peer_subset{
                   lowest_stream_id=Lowest
                  }, _StreamSet)
  when Id < Lowest ->
    #closed_stream{id=Id};
get_from_subset(Id,
                #peer_subset{
                   next_available_stream_id=Next
                  }, _StreamSet)
  when Id >= Next ->
    #idle_stream{id=Id};
get_from_subset(Id, _PeerSubset, StreamSet) ->
    case ets:lookup(StreamSet#stream_set.table, Id)  of
        [] ->
            #closed_stream{id=Id};
        [Stream] ->
            Stream
    end.

-spec upsert(
        Stream :: stream(),
        StreamSet :: stream_set()) ->
                    stream_set()
                  | {error, error_code()}.
%% Can't store idle streams
upsert(#idle_stream{}, StreamSet) ->
    StreamSet;
upsert(Stream, StreamSet) ->
    StreamId = stream_id(Stream),
    PeerSubset = get_peer_subset(StreamId, StreamSet),
    case upsert_peer_subset(Stream, PeerSubset, StreamSet) of
        {error, Code} ->
            {error, Code};
        unchanged ->
            StreamSet;
        NewPeerSubset ->
            set_peer_subset(StreamId, StreamSet, NewPeerSubset)
    end.

-spec upsert_peer_subset(
        Stream :: closed_stream() | active_stream(),
        PeerSubset :: peer_subset(),
        StreamSet :: stream_set()
                      ) ->
                    peer_subset()
                  | unchanged
                  | {error, error_code()}.
%% Case 1: We're upserting a closed stream, it contains garbage we
%% don't care about and it's in the range of streams we're actively
%% tracking We remove it, and move the lowest_active pointer.
upsert_peer_subset(
  #closed_stream{
     id=Id,
     garbage=true
    },
  PeerSubset, StreamSet)
  when Id >= PeerSubset#peer_subset.lowest_stream_id,
       Id < PeerSubset#peer_subset.next_available_stream_id ->
    OldStream = get(Id, StreamSet),
    OldType = type(OldStream),
    ActiveDiff =
        case OldType of
            closed -> 0;
            active -> -1
        end,

    ets:delete(StreamSet#stream_set.table, Id),
    %% NewActive could now have a #closed_stream with no information
    %% in it as the lowest active stream, so we should drop those.
    NewActive = drop_unneeded_streams(StreamSet, Id),

    case NewActive of
        [] ->
            PeerSubset#peer_subset{
              lowest_stream_id=PeerSubset#peer_subset.next_available_stream_id,
              active_count=0
             };
        [NewLowestStream|_] ->
            NewLowest = stream_id(NewLowestStream),
            PeerSubset#peer_subset{
              lowest_stream_id=NewLowest,
              active_count=PeerSubset#peer_subset.active_count+ActiveDiff
             }
    end;
%% Case 2: Like case 1, but it's not garbage
upsert_peer_subset(
  #closed_stream{
     id=Id,
     garbage=false
    }=Closed,
  PeerSubset, StreamSet)
  when Id >= PeerSubset#peer_subset.lowest_stream_id,
       Id < PeerSubset#peer_subset.next_available_stream_id ->
    OldStream = get(Id, StreamSet),
    OldType = type(OldStream),
    ActiveDiff =
        case OldType of
            closed -> 0;
            active -> -1
        end,

    ets:insert(StreamSet#stream_set.table, Closed),
    PeerSubset#peer_subset{
      active_count=PeerSubset#peer_subset.active_count+ActiveDiff
     };
%% Case 3: It's closed, but greater than or equal to next available:
upsert_peer_subset(
  #closed_stream{
     id=Id
    } = Closed,
  PeerSubset, StreamSet)
 when Id >= PeerSubset#peer_subset.next_available_stream_id ->
    ets:insert(StreamSet#stream_set.table, Closed),
    PeerSubset#peer_subset{
      next_available_stream_id=Id+2
     };
%% Case 4: It's active, and in the range we're working with
upsert_peer_subset(
  #active_stream{
     id=Id
    }=Stream,
  PeerSubset, StreamSet)
  when Id >= PeerSubset#peer_subset.lowest_stream_id,
       Id < PeerSubset#peer_subset.next_available_stream_id ->
    ets:insert(StreamSet#stream_set.table, Stream),
    unchanged;
%% Case 5: It's active, but it wasn't active before and activating it
%% would exceed our concurrent stream limits
upsert_peer_subset(
  #active_stream{},
  PeerSubset, _StreamSet)
  when PeerSubset#peer_subset.max_active =/= unlimited,
       PeerSubset#peer_subset.active_count >= PeerSubset#peer_subset.max_active ->
    {error, ?REFUSED_STREAM};
%% Case 6: It's active, and greater than the range we're tracking
upsert_peer_subset(
  #active_stream{
     id=Id
    }=Stream,
  PeerSubset, StreamSet)
 when Id >= PeerSubset#peer_subset.next_available_stream_id ->
    ets:insert(StreamSet#stream_set.table, Stream),
    PeerSubset#peer_subset{
      next_available_stream_id=Id+2,
      active_count=PeerSubset#peer_subset.active_count+1
     };
%% Catch All
%% TODO: remove this match and crash instead?
upsert_peer_subset(
  _Stream,
  _PeerSubset, _StreamSet) ->
    unchanged.


drop_unneeded_streams(StreamSet, Id) ->
    Streams = case {StreamSet#stream_set.type, Id rem 2} of
                  {client, 0} ->
                      %% their streams
                      their_active_streams(StreamSet);
                  {client, 1} ->
                      %% my streams
                      my_active_streams(StreamSet);
                  {server, 0} ->
                      %% my streams
                      my_active_streams(StreamSet);
                  {server, 1} ->
                      %% their streams
                      their_active_streams(StreamSet)
              end,
    SortedStreams = lists:keysort(2, Streams),
    drop_unneeded_streams_(SortedStreams, StreamSet).

drop_unneeded_streams_([#closed_stream{garbage=true, id=Id}|T], StreamSet) ->
    ets:delete(StreamSet#stream_set.table, Id),
    drop_unneeded_streams_(T, StreamSet);
drop_unneeded_streams_(Other, _StreamSet) ->
    Other.

-spec close(
        Stream :: stream(),
        Response :: garbage | {hpack:headers(), iodata()},
        Streams :: stream_set()
                   ) ->
                   { stream(), stream_set()}.
close(Stream,
      garbage,
      StreamSet) ->
    Closed = #closed_stream{
                id = stream_id(Stream),
                garbage=true
               },
    {Closed, upsert(Closed, StreamSet)};
close(Closed=#closed_stream{},
      _Response,
      Streams) ->
    {Closed, Streams};
close(_Idle=#idle_stream{id=StreamId},
      {Headers, Body, Trailers},
      Streams) ->
    Closed = #closed_stream{
                id=StreamId,
                response_headers=Headers,
                response_body=Body,
                response_trailers=Trailers
               },
    {Closed, upsert(Closed, Streams)};
close(#active_stream{
         id=Id,
         notify_pid=NotifyPid
        },
      {Headers, Body, Trailers},
      Streams) ->
    Closed = #closed_stream{
                id=Id,
                response_headers=Headers,
                response_body=Body,
                response_trailers=Trailers,
                notify_pid=NotifyPid
               },
    {Closed, upsert(Closed, Streams)}.

-spec update_all_recv_windows(Delta :: integer(),
                              Streams:: stream_set()) ->
                                     stream_set().
update_all_recv_windows(Delta, Streams) ->

    ets:select_replace(Streams#stream_set.table,
      ets:fun2ms(fun(S=#active_stream{recv_window_size=Size}) ->
                         S#active_stream{recv_window_size=Size+Delta}
                 end)),
    Streams.

-spec update_all_send_windows(Delta :: integer(),
                              Streams:: stream_set()) ->
                                     stream_set().
update_all_send_windows(Delta, Streams) ->
    ets:select_replace(Streams#stream_set.table,
      ets:fun2ms(fun(S=#active_stream{send_window_size=Size}) ->
                         S#active_stream{send_window_size=Size+Delta}
                 end)),
    Streams.

-spec update_their_max_active(NewMax :: non_neg_integer() | unlimited,
                             Streams :: stream_set()) ->
                                    stream_set().
update_their_max_active(NewMax, Streams) ->
    Theirs = get_their_peers(Streams),
    set_their_peers(Streams, Theirs#peer_subset{max_active=NewMax}),
    Streams.

get_next_available_stream_id(Streams) ->
    (get_my_peers(Streams))#peer_subset.next_available_stream_id.

-spec update_my_max_active(NewMax :: non_neg_integer() | unlimited,
                             Streams :: stream_set()) ->
                                    stream_set().
update_my_max_active(NewMax, Streams) ->
    Mine = get_my_peers(Streams),
    set_my_peers(Streams, Mine#peer_subset{max_active=NewMax}),
    Streams.

-spec send_what_we_can(StreamId :: all | stream_id(),
                       Streams :: stream_set()) ->
                              {NewConnSendWindowSize :: integer(),
                               NewStreams :: stream_set()}.
send_what_we_can(all, Streams) ->

    ConnSendWindowSize = socket_send_window_size(Streams),
    {_SelfSettings, PeerSettings} = get_settings(Streams),
    MaxFrameSize = PeerSettings#settings.max_frame_size,
    AfterPeerWindowSize = c_send_what_we_can(
                            ConnSendWindowSize,
                            MaxFrameSize,
                            get_their_active_streams(Streams),
                            Streams),
    AfterAfterWindowSize = c_send_what_we_can(
                             AfterPeerWindowSize,
                             MaxFrameSize,
                             get_my_active_streams(Streams),
                             Streams),

    set_socket_send_window_size(AfterAfterWindowSize, Streams),
    {AfterAfterWindowSize,
     Streams};
send_what_we_can(StreamId, Streams) ->
    ConnSendWindowSize = socket_send_window_size(Streams),
    {_SelfSettings, PeerSettings} = get_settings(Streams),
    MaxFrameSize = PeerSettings#settings.max_frame_size,
    {NewConnSendWindowSize, NewStream} =
        s_send_what_we_can(ConnSendWindowSize,
                           MaxFrameSize,
                           Streams#stream_set.socket,
                           get(StreamId, Streams)),
    set_socket_send_window_size(NewConnSendWindowSize, Streams),
    {NewConnSendWindowSize,
     upsert(NewStream, Streams)}.

%% Send at the connection level
-spec c_send_what_we_can(ConnSendWindowSize :: integer(),
                         MaxFrameSize :: non_neg_integer(),
                         Streams :: [stream()],
                         StreamSet :: stream_set()
                        ) ->
                                integer().
%% If we hit =< 0, done
c_send_what_we_can(ConnSendWindowSize, _MFS, _Streams, _StreamSet)
  when ConnSendWindowSize =< 0 ->
    ConnSendWindowSize;
%% If we hit end of streams list, done
c_send_what_we_can(SWS, _MFS, [], _StreamSet) ->
    SWS;
%% Otherwise, try sending on the working stream
c_send_what_we_can(SWS, MFS, [S|Streams], StreamSet) ->
    {NewSWS, NewS} = s_send_what_we_can(SWS, MFS, StreamSet#stream_set.socket, S),
    ets:insert(StreamSet#stream_set.table, NewS),
    c_send_what_we_can(NewSWS, MFS, Streams, StreamSet).

%% Send at the stream level
-spec s_send_what_we_can(SWS :: integer(),
                         MFS :: non_neg_integer(),
                         Socket :: sock:socket(),
                         Stream :: stream()) ->
                                {integer(), stream()}.
s_send_what_we_can(SWS, _, _, #active_stream{queued_data=Data,
                                          trailers=undefined}=S)
  when is_atom(Data) ->
    {SWS, S};
s_send_what_we_can(SWS, _, _, #active_stream{queued_data=Data,
                                          id=_StreamId,
                                          pid=Pid,
                                          trailers=Trailers}=S)
  when is_atom(Data) ->
    ct:pal("sending trailers on stream ~p", [_StreamId]),
    h2_stream:send_trailers(Pid, Trailers),
    {SWS, S#active_stream{trailers=undefined}};
s_send_what_we_can(SWS, MFS, Socket, #active_stream{}=Stream) ->
    %% We're coming in here with three numbers we need to look at:
    %% * Connection send window size
    %% * Stream send window size
    %% * Maximimum frame size

    %% If none of them are zero, we have to send something, so we're
    %% going to figure out what's the biggest number we can send. If
    %% that's more than we have to send, we'll send everything and put
    %% an END_STREAM flag on it. Otherwise, we'll send as much as we
    %% can. Then, based on which number was the limiting factor, we'll
    %% make another decision

    %% If it was MAX_FRAME_SIZE, then we recurse into this same
    %% function, because we're able to send another frame of some
    %% length.

    %% If it was connection send window size, we're blocked at the
    %% connection level and we should break out of this recursion

    %% If it was stream send_window size, we're blocked on this
    %% stream, but other streams can still go, so we'll break out of
    %% this recursion, but not the connection level

    SSWS = Stream#active_stream.send_window_size,
    QueueSize = byte_size(Stream#active_stream.queued_data),

    {MaxToSend, ExitStrategy} =
        case {MFS =< SWS andalso MFS =< SSWS, SWS < SSWS} of
            %% If MAX_FRAME_SIZE is the smallest, send one and recurse
            {true, _} ->
                {MFS, max_frame_size};
            {false, true} ->
                {SWS, connection};
            _ ->
                {SSWS, stream}
        end,

        ct:pal("sending ~p of ~p", [MaxToSend, QueueSize]),
    {Frame, SentBytes, NewS} =
        case MaxToSend > QueueSize of
            true ->
                Flags = case Stream#active_stream.body_complete of
                            true ->
                                case Stream of
                                    #active_stream{trailers=undefined} ->
                                        ?FLAG_END_STREAM;
                                    _ ->
                                        0
                                end;
                            false -> 0
                        end,
                %% We have the power to send everything
                {{#frame_header{
                     stream_id=Stream#active_stream.id,
                     flags=Flags,
                     type=?DATA,
                     length=QueueSize
                    },
                  h2_frame_data:new(Stream#active_stream.queued_data)},  %% Full Body
                 QueueSize,
                 Stream#active_stream{
                   queued_data=done,
                   send_window_size=SSWS-QueueSize}};
            false ->
                <<BinToSend:MaxToSend/binary,Rest/binary>> = Stream#active_stream.queued_data,
                {{#frame_header{
                     stream_id=Stream#active_stream.id,
                     type=?DATA,
                     length=MaxToSend
                    },
                  h2_frame_data:new(BinToSend)},
                 MaxToSend,
                 Stream#active_stream{
                   queued_data=Rest,
                   send_window_size=SSWS-MaxToSend}}
        end,

        ct:pal("sending data ~p via ~p", [Frame, Stream#active_stream.pid]),
        h2_stream:send_data(Stream#active_stream.pid, Frame),
        %sock:send(Socket, h2_frame:to_binary(Frame)),a

    NewS1 = case NewS of
                #active_stream{trailers=undefined} ->
                    NewS;
                #active_stream{pid=Pid,
                               queued_data=done,
                               trailers=Trailers1} ->
                    ct:pal("sending trailers on stream ~p", [NewS#active_stream.id]),
                    h2_stream:send_trailers(Pid, Trailers1),
                    NewS#active_stream{trailers=undefined};
                _ ->
                    NewS
            end,

    case ExitStrategy of
        max_frame_size ->
            s_send_what_we_can(SWS - SentBytes, Socket, MFS, NewS1);
        stream ->
            {SWS - SentBytes, NewS1};
        connection ->
            {SWS - SentBytes, NewS1}
    end;
s_send_what_we_can(SWS, _MFS, _Socket, NonActiveStream) ->
    {SWS, NonActiveStream}.


%% Record Accessors
-spec stream_id(
        Stream :: stream()) ->
                       stream_id().
stream_id(#idle_stream{id=SID}) ->
    SID;
stream_id(#active_stream{id=SID}) ->
    SID;
stream_id(#closed_stream{id=SID}) ->
    SID.

-spec pid(stream()) -> pid() | undefined.
pid(#active_stream{pid=Pid}) ->
    Pid;
pid(_) ->
    undefined.

-spec stream_set_type(stream_set()) -> client | server.
stream_set_type(StreamSet) ->
    StreamSet#stream_set.type.

-spec type(stream()) -> idle | active | closed.
type(#idle_stream{}) ->
    idle;
type(#active_stream{}) ->
    active;
type(#closed_stream{}) ->
    closed.

queued_data(#active_stream{queued_data=QD}) ->
    QD;
queued_data(_) ->
    undefined.

update_trailers(Trailers, Stream=#active_stream{}) ->
    Stream#active_stream{trailers=Trailers}.

update_data_queue(
  NewBody,
  BodyComplete,
  #active_stream{} = Stream) ->
    Stream#active_stream{
      queued_data=NewBody,
      body_complete=BodyComplete
     };
update_data_queue(_, _, S) ->
    S.

response(#closed_stream{
            response_headers=Headers,
            response_trailers=Trailers,
            response_body=Body}) ->
    Encoding = case lists:keyfind(<<"content-encoding">>, 1, Headers) of
        false -> identity;
        {_, Encoding0} -> binary_to_atom(Encoding0, 'utf8')
    end,
    {Headers, decode_body(Body, Encoding), Trailers};
response(_) ->
    no_response.

decode_body(Body, identity) ->
    Body;
decode_body(Body, gzip) ->
    zlib:gunzip(Body);
decode_body(Body, zip) ->
    zlib:unzip(Body);
decode_body(Body, compress) ->
    zlib:uncompress(Body);
decode_body(Body, deflate) ->
    Z = zlib:open(),
    ok = zlib:inflateInit(Z, -15),
    Decompressed = try zlib:inflate(Z, Body) catch E:V -> {E,V} end,
    ok = zlib:inflateEnd(Z),
    ok = zlib:close(Z),
    iolist_to_binary(Decompressed).

recv_window_size(#active_stream{recv_window_size=RWS}) ->
    RWS;
recv_window_size(_) ->
    undefined.

decrement_recv_window(
  L,
  #active_stream{recv_window_size=RWS}=Stream
 ) ->
    Stream#active_stream{
      recv_window_size=RWS-L
     };
decrement_recv_window(_, S) ->
    S.

decrement_socket_recv_window(L, #stream_set{atomics = Atomics}) ->
    atomics:sub_get(Atomics, ?RECV_WINDOW_SIZE, L).

increment_socket_recv_window(L, #stream_set{atomics = Atomics}) ->
    atomics:add_get(Atomics, ?RECV_WINDOW_SIZE, L).

socket_recv_window_size(#stream_set{atomics = Atomics}) ->
    atomics:get(Atomics, ?RECV_WINDOW_SIZE).

set_socket_recv_window_size(Value, #stream_set{atomics = Atomics}) ->
    atomics:put(Atomics, ?RECV_WINDOW_SIZE, Value).

decrement_socket_send_window(L, #stream_set{atomics = Atomics}) ->
    atomics:sub_get(Atomics, ?SEND_WINDOW_SIZE, L).

increment_socket_send_window(L, #stream_set{atomics = Atomics}) ->
    atomics:add_get(Atomics, ?SEND_WINDOW_SIZE, L).

socket_send_window_size(#stream_set{atomics = Atomics}) ->
    atomics:get(Atomics, ?SEND_WINDOW_SIZE).

set_socket_send_window_size(Value, #stream_set{atomics = Atomics}) ->
    atomics:put(Atomics, ?SEND_WINDOW_SIZE, Value).


send_window_size(#active_stream{send_window_size=SWS}) ->
    SWS;
send_window_size(_) ->
    undefined.

increment_send_window_size(
  WSI,
  #active_stream{send_window_size=SWS}=Stream) ->
    Stream#active_stream{
      send_window_size=SWS+WSI
     };
increment_send_window_size(_WSI, Stream) ->
    Stream.

stream_pid(#active_stream{pid=Pid}) ->
    Pid;
stream_pid(_) ->
    undefined.

%% the false clause is here as an artifact of us using a simple
%% lists:keyfind
notify_pid(#idle_stream{}) ->
    undefined;
notify_pid(#active_stream{notify_pid=Pid}) ->
    Pid;
notify_pid(#closed_stream{notify_pid=Pid}) ->
    Pid.

%% The number of #active_stream records
-spec my_active_count(stream_set()) -> non_neg_integer().
my_active_count(SS) ->
    (get_my_peers(SS))#peer_subset.active_count.

%% The number of #active_stream records
-spec their_active_count(stream_set()) -> non_neg_integer().
their_active_count(SS) ->
    (get_their_peers(SS))#peer_subset.active_count.

%% The list of #active_streams, and un gc'd #closed_streams
-spec my_active_streams(stream_set()) -> [stream()].
my_active_streams(SS) ->
    case SS#stream_set.type of
        client ->
            ets:select(SS#stream_set.table, ets:fun2ms(fun(S=#active_stream{id=Id}) when Id rem 2 == 1 -> S;
                                                          (S=#closed_stream{id=Id}) when Id rem 2 == 1 -> S
                                                       end));
        server ->
            ets:select(SS#stream_set.table, ets:fun2ms(fun(S=#active_stream{id=Id}) when Id rem 2 == 0 -> S;
                                                          (S=#closed_stream{id=Id}) when Id rem 2 == 0 -> S
                                                       end))
    end.

%% The list of #active_streams, and un gc'd #closed_streams
-spec their_active_streams(stream_set()) -> [stream()].
their_active_streams(SS) ->
    case SS#stream_set.type of
        client ->
            ets:select(SS#stream_set.table, ets:fun2ms(fun(S=#active_stream{id=Id}) when Id rem 2 == 0 -> S;
                                                          (S=#closed_stream{id=Id}) when Id rem 2 == 0 -> S
                                                       end));
        server ->
            ets:select(SS#stream_set.table, ets:fun2ms(fun(S=#active_stream{id=Id}) when Id rem 2 == 1 -> S;
                                                          (S=#closed_stream{id=Id}) when Id rem 2 == 1 -> S
                                                       end))
    end.

%% My MCS (max_active)
-spec my_max_active(stream_set()) -> non_neg_integer().
my_max_active(SS) ->
    (get_my_peers(SS))#peer_subset.max_active.

%% Their MCS (max_active)
-spec their_max_active(stream_set()) -> non_neg_integer().
their_max_active(SS) ->
    (get_their_peers(SS))#peer_subset.max_active.

take_lock(StreamSet, Locks, Fun) ->
    ct:pal("taking locks ~p ~p", [Locks, self()]),
    [ take_lock(lock_to_index(Lock), StreamSet) || Lock <- lists:sort(Locks) ],
    Res = catch Fun(),
    %ct:pal("lock fun res ~p", [Res]),
    [ release_lock(lock_to_index(Lock), StreamSet) || Lock <- lists:sort(Locks) ],
    Res.

take_lock(Index, StreamSet=#stream_set{atomics=Atomics}) ->
    case atomics:compare_exchange(Atomics, Index, ?UNLOCKED, ?SHARED_LOCK) of
        ok ->
            ct:pal("took lock ~p ~p", [Index, self()]),
            hold_lock(Index, StreamSet),
            ok;
        ?SHARED_LOCK ->
            ct:pal("sharing lock ~p ~p", [Index, self()]),
            %% someone else already has a shared lock, this is fine
            hold_lock(Index, StreamSet),
            ok;
        ?EXCLUSIVE_LOCK ->
            ct:pal("waiting for lock ~p ~p", [Index, self()]),
            %% need to wait for the exclusive access to be released
            wait_lock(Index, StreamSet)
    end.

take_exclusive_lock(StreamSet, Locks, Fun) ->
    ct:pal("taking exclusive locks ~p ~p", [Locks, self()]),
    [ take_exclusive_lock(lock_to_index(Lock), StreamSet) || Lock <- lists:sort(Locks) ],
    Res = catch Fun(),
    %ct:pal("exclusive lock fun res ~p", [Res]),
    [ release_exclusive_lock(lock_to_index(Lock), StreamSet) || Lock <- lists:sort(Locks) ],
    Res.


take_exclusive_lock(Index, StreamSet=#stream_set{atomics=Atomics}) ->
    case atomics:compare_exchange(Atomics, Index, ?UNLOCKED, ?EXCLUSIVE_LOCK) of
        ok ->
            ct:pal("got exclusive lock ~p ~p", [Index, self()]),
            hold_lock(Index, StreamSet),
            ok;
        ?SHARED_LOCK ->
            %% check if its only us holding the lock
            JustUs = [self()],
            ct:pal("upgrading shared lock to exclusive lock"),
            case ets:select_count(StreamSet#stream_set.table, ets:fun2ms(fun(#lock{id={lock, I}, holders=H}=Lock) when I == Index, H == JustUs -> true end)) of
                1 ->
                    ct:pal("upgrade lock ~p to exclusive succeeded ~p", [Index, self()]),
                    ok = atomics:compare_exchange(Atomics, Index, ?SHARED_LOCK, ?EXCLUSIVE_LOCK),
                    hold_lock(Index, StreamSet);
                0 ->
                    ct:pal("upgrade lock ~p to exclusive failed ~p", [Index, self()]),
                    %% someone else already has a shared lock, this is fine
                    wait_lock(Index, StreamSet),
                    take_exclusive_lock(Index, StreamSet)
            end;
        ?EXCLUSIVE_LOCK ->
            JustUs = [self()],
            case ets:select_count(StreamSet#stream_set.table, ets:fun2ms(fun(#lock{id={lock, I}, holders=H}=Lock) when I == Index, H == JustUs -> true end)) of
                1 ->
                    ct:pal("already held exclusive lock ~p ~p", [Index, self()]),
                    hold_lock(Index, StreamSet),
                    ok;
                0 ->
                    case ets:select_count(StreamSet#stream_set.table, ets:fun2ms(fun(#lock{id={lock, I}, holders=H}=Lock) when I == Index, H == [] -> true end)) of
                        1 ->
                            ct:pal("~p claiming orphaned exclusive lock", [self()]),
                            Self = self(),
                            case ets:select_replace(StreamSet#stream_set.table,
                                                    ets:fun2ms(fun(#lock{id={lock, I}, holders=[]}=Lock) when I == Index -> Lock#lock{holders=[Self]} end)) of
                                1 ->
                                    ok;
                                _ ->
                                    ct:pal("waiting for exclusive lock ~p ~p", [Index, self()]),
                                    ct:pal("~p", [ets:lookup(StreamSet#stream_set.table, {lock, Index})]),
                                    %% need to wait for the exclusive access to be released
                                    wait_lock(Index, StreamSet),
                                    take_exclusive_lock(Index, StreamSet)
                            end;
                        _ ->
                            ct:pal("waiting for exclusive lock ~p ~p", [Index, self()]),
                            ct:pal("~p", [ets:lookup(StreamSet#stream_set.table, {lock, Index})]),
                            %% need to wait for the exclusive access to be released
                            wait_lock(Index, StreamSet),
                            take_exclusive_lock(Index, StreamSet)
                    end
            end
    end.


hold_lock(Index, StreamSet) ->
    Self = self(),
    1 = ets:select_replace(StreamSet#stream_set.table,
                       ets:fun2ms(fun(#lock{id={lock, I}, holders=H}=Lock) when I == Index -> Lock#lock{holders=[Self|H]} end)).

wait_lock(Index, StreamSet) ->
    Self = self(),
    Ref = make_ref(),
    1 = ets:select_replace(StreamSet#stream_set.table,
                       ets:fun2ms(fun(#lock{id={lock, I}, waiters=H}=Lock) when I == Index -> Lock#lock{waiters=[{Self, Ref}|H]} end)),
    Holders = (hd(ets:lookup(StreamSet#stream_set.table, {lock, Index})))#lock.holders,
    Monitors = [ erlang:monitor(process, Holder) || Holder <- Holders ],
    wait_ref(Index, Ref, Monitors, StreamSet).

wait_ref(Index, Ref, Monitors, StreamSet) ->
    receive
        {'DOWN', MRef, process, _Handler, Reason}=Msg ->
            case lists:member(MRef, Monitors) of
                true ->
                    ct:pal("handler died unexpectedly ~p ~p", [_Handler, Reason]),
                    wait_ref(Index, Ref, Monitors -- [MRef], StreamSet);
                false ->
                    self() ! Msg,
                    wait_ref(Index, Ref, Monitors, StreamSet)
            end;
        {Ref, unlocked} ->
            ok
    after 1000 ->
              case ets:select_count(StreamSet#stream_set.table, ets:fun2ms(fun(#lock{id={lock, I}, holders=[]}=Lock) when I == Index -> true end)) of
                  1 ->
                      ct:pal("orphaned lock"),
                      ok;
                  _ ->
                      ct:pal("~p still waiting on ~p", [self(), Index]),
                      ct:pal("~p", [ets:lookup(StreamSet#stream_set.table, {lock, Index})]),
                      wait_ref(Index, Ref, Monitors, StreamSet)
              end
    end.

release_lock(Index, StreamSet) ->
    case ets:lookup(StreamSet#stream_set.table, {lock, Index}) of
        [#lock{holders=Holders, waiters=Waiters}] ->
            ct:pal("lock ~p holders ~p ~p", [Index, Holders, self()]),
            Self = self(),
            %% filter out any dead holders and ourself
            case [ P || P <- Holders, erlang:is_process_alive(P), P /= Self ] of
                [] ->
                    ct:pal("releasing lock ~p ;  last holder ~p", [Index, self()]),
                    %% we were the last holder
                    case ets:select_replace(StreamSet#stream_set.table, ets:fun2ms(fun(#lock{id={lock, I}, holders=H}=Lock) when I == Index, H == Holders -> Lock#lock{waiters=[], holders=[]} end)) of
                        1 ->
                            case atomics:compare_exchange(StreamSet#stream_set.atomics, Index, ?SHARED_LOCK, ?UNLOCKED) of
                                ok ->
                                    ct:pal("lock ~p released ~p", [Index, self()]),
                                    [ Pid ! {Ref, unlocked} || {Pid, Ref} <- Waiters ];
                                ?EXCLUSIVE_LOCK ->
                                    ct:pal("lock ~p upgraded to exclusive? ~p", [Index, self()]),
                                    %% TODO this needs to be tracked better because when we upgrade a lock or re-take a lock
                                    %% we need to know how many times to unlock it, and into what state
                                    case atomics:compare_exchange(StreamSet#stream_set.atomics, Index, ?EXCLUSIVE_LOCK, ?UNLOCKED) of
                                        ok -> ok;
                                        ?UNLOCKED ->
                                            ok
                                    end,
                                    ct:pal("~p", [ets:lookup(StreamSet#stream_set.table, {lock, Index})]),
                                    ok
                            end,
                            ok;
                        N ->
                            ct:pal("select_replace returned ~p", [N]),
                            ok
                    end;
                OtherHolders ->
                    ct:pal("releasing lock ~p ; other holders ~p ~p", [Index, OtherHolders, self()]),
                    case ets:select_replace(StreamSet#stream_set.table, ets:fun2ms(fun(#lock{id={lock, I}, holders=H}=Lock) when I == Index, H == Holders -> Lock#lock{holders=OtherHolders} end)) of
                        1 ->
                            ct:pal("released lock ~p ~p ", [Index, self()]),
                            ok;
                        _ ->
                            ct:pal("failed to release lock ~p ~p", [Index, self()]),
                            release_lock(Index, StreamSet)
                    end
            end
    end.

release_exclusive_lock(Index, StreamSet) ->
    Self = self(),
    case ets:lookup(StreamSet#stream_set.table, {lock, Index}) of
        [#lock{holders=H, waiters=W}] when H /= [Self] ->
            ct:pal("released re-entrant exclusive lock ~p ~p", [Index, self()]),
            NewHolders = H -- [Self],
            ct:pal("~p new holders ~p", [self(), NewHolders]),
            %true = lists:all(fun(E) -> E == Self end, NewHolders),
            1 = ets:select_replace(StreamSet#stream_set.table, ets:fun2ms(fun(#lock{id={lock, I}}=Lock) when I == Index -> Lock#lock{waiters=W, holders=NewHolders} end)),
            ok;
        [#lock{waiters=Waiters}] ->
            ct:pal("released exclusive lock ~p ~p", [Index, self()]),
            1 = ets:select_replace(StreamSet#stream_set.table, ets:fun2ms(fun(#lock{id={lock, I}}=Lock) when I == Index -> Lock#lock{waiters=[], holders=[]} end)),
            ok = atomics:compare_exchange(StreamSet#stream_set.atomics, Index, ?EXCLUSIVE_LOCK, ?UNLOCKED),
            [ Pid ! {Ref, unlocked} || {Pid, Ref} <- Waiters ],
            ok
    end.

lock_to_index(socket) -> ?SEND_LOCK;
lock_to_index(settings) -> ?SETTINGS_LOCK;
lock_to_index(streams) -> ?STREAMS_LOCK;
lock_to_index(encoder) -> ?ENCODER_LOCK.
