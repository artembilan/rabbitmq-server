-module(mc_amqp).
-behaviour(mc).

% -include_lib("rabbit_common/include/rabbit_framing.hrl").
-include_lib("amqp10_common/include/amqp10_framing.hrl").
-include("mc.hrl").

-export([
         init/1,
         size/1,
         x_header/2,
         property/2,
         routing_headers/2,
         get_property/2,
         convert_to/2,
         convert_from/2,
         protocol_state/2,
         serialize/2,
         prepare/2
        ]).

-import(rabbit_misc,
        [maps_put_truthy/3,
         maps_put_falsy/3
        ]).

-type message_section() ::
    #'v1_0.header'{} |
    #'v1_0.delivery_annotations'{} |
    #'v1_0.message_annotations'{} |
    #'v1_0.properties'{} |
    #'v1_0.application_properties'{} |
    #'v1_0.data'{} |
    #'v1_0.amqp_sequence'{} |
    #'v1_0.amqp_value'{} |
    #'v1_0.footer'{}.

-define(SIMPLE_VALUE(V), is_binary(V) orelse
                         is_number(V) orelse
                         is_boolean(V)).

-type opt(T) :: T | undefined.
-type amqp10_data() :: [#'v1_0.amqp_sequence'{} | #'v1_0.data'{}] |
                       #'v1_0.amqp_value'{}.
%% TODO: no need to keep section records, only contents really needed
%% for DA / MA and APs
-record(msg,
        {
         header :: opt(#'v1_0.header'{}),
         delivery_annotations :: opt(#'v1_0.delivery_annotations'{}),
         message_annotations :: opt(#'v1_0.message_annotations'{}),
         properties :: opt(#'v1_0.properties'{}),
         application_properties :: opt(#'v1_0.application_properties'{}),
         data = [] :: amqp10_data(),
         footer :: opt(#'v1_0.footer'{})
        }).

-opaque state() :: #msg{}.

-export_type([
              state/0,
              message_section/0
             ]).

%% mc implementation
init(Sections) when is_list(Sections) ->
    %% TODO: project essential header values, (durable, etc)
    Msg = decode(Sections, #msg{}),
    init(Msg);
init(#msg{} = Msg) ->
    %% TODO: as the essential annotations, durable, priority, ttl and delivery_count
    %% is all we are interested in it isn't necessary to keep hold of the
    %% incoming AMQP header inside the state
    Anns = essential_properties(Msg),
    {Msg, Anns}.

convert_from(?MODULE, Sections) ->
    element(1, init(Sections));
convert_from(_SourceProto, _) ->
    not_implemented.

size(#msg{data = Body}) ->
    %% TODO how to estimate anything but data sections?
    BodySize = if is_list(Body) ->
                      lists:foldl(
                        fun(#'v1_0.data'{content = Data}, Acc) ->
                                iolist_size(Data) + Acc;
                           (#'v1_0.amqp_sequence'{content = _}, Acc) ->
                                Acc
                        end, 0, Body);
                  is_record(Body, 'v1_0.amqp_value') ->
                      0
               end,
    {_MetaSize = 0, BodySize}.

x_header(Key, Msg) ->
    message_annotation(Key, Msg, undefined).

property(correlation_id, #msg{properties = #'v1_0.properties'{correlation_id = Corr}}) ->
    Corr;
property(message_id, #msg{properties = #'v1_0.properties'{message_id = MsgId}}) ->
     MsgId;
property(_Prop, #msg{}) ->
    undefined.

routing_headers(Msg, Opts) ->
    IncludeX = lists:member(x_header, Opts),
    X = case IncludeX of
            true ->
                message_annotations_as_simple_map(Msg);
            false ->
                #{}
        end,
    application_properties_as_simple_map(Msg, X).


get_property(durable, Msg) ->
    case Msg of
        #msg{header = #'v1_0.header'{durable = Durable}}
          when is_atom(Durable) ->
            %% TODO: is there another boolean format with a tag?
            Durable;
        _ ->
            %% fallback in case the source protocol was old AMQP 0.9.1
            case message_annotation(<<"x-basic-delivery-mode">>, Msg, 2) of
                {ubyte, 2} ->
                    true;
                _ ->
                    false
            end
    end;
get_property(timestamp, Msg) ->
    case Msg of
        #msg{properties = #'v1_0.properties'{creation_time = {timestamp, Ts}}} ->
            Ts;
        _ ->
            undefined
    end;
get_property(correlation_id, Msg) ->
    case Msg of
        #msg{properties = #'v1_0.properties'{correlation_id = {_Type, CorrId}}} ->
            CorrId;
        _ ->
            undefined
    end;
get_property(message_id, Msg) ->
    case Msg of
        #msg{properties = #'v1_0.properties'{message_id = {_Type, CorrId}}} ->
            CorrId;
        _ ->
            undefined
    end;
get_property(ttl, Msg) ->
    case Msg of
        #msg{header = #'v1_0.header'{ttl = {_, Ttl}}} ->
            Ttl;
        _ ->
            %% fallback in case the source protocol was AMQP 0.9.1
            case message_annotation(<<"x-basic-expiration">>, Msg, undefined) of
                {utf8, Expiration}  ->
                    {ok, Ttl} = rabbit_basic:parse_expiration(Expiration),
                    Ttl;
                _ ->
                    undefined
            end
    end;
get_property(priority, Msg) ->
    case Msg of
        #msg{header = #'v1_0.header'{priority = {ubyte, Priority}}} ->
            Priority;
        _ ->
            %% fallback in case the source protocol was AMQP 0.9.1
            case message_annotation(<<"x-basic-priority">>, Msg, undefined) of
                {_, Priority}  ->
                    Priority;
                _ ->
                    undefined
            end
    end;
get_property(_P, _Msg) ->
    undefined.

convert_to(?MODULE, Msg) ->
    Msg;
convert_to(TargetProto, #msg{header = Header,
                             message_annotations = MA,
                             properties = P,
                             application_properties = AP,
                             data = Data}) ->
    Sects = lists_prepend_t(
              Header,
              lists_prepend_t(
                MA,
                lists_prepend_t(
                  P,
                  lists_prepend_t(
                    AP,
                    Data)))),
    %% convert_from(mc_amqp, Sections) expects a flat list of amqp sections
    %% and the body could be a list itself (or an amqp_value)
    Sections = lists:flatten(Sects),
    TargetProto:convert_from(?MODULE, Sections).

protocol_state(_S, _Anns) ->
    undefined.

serialize(#msg{header = Header,
               message_annotations = MA0,
               properties = P,
               application_properties = AP,
               data = Data}, Anns) ->
    Exchange = maps:get(exchange, Anns),
    [RKey | _] = maps:get(routing_keys, Anns),

    %% any x-* annotations get added as message annotations
    AnnsToAdd = maps:filter(
                  fun (<<"x-", _Rest/binary>>, _Val) ->
                          true;
                      (_, _) ->
                          false
                  end, Anns),

    MA = add_message_annotations(
           AnnsToAdd#{<<"x-exchange">> => wrap(Exchange),
                      <<"x-routing-key">> => wrap(RKey)}, MA0),
    [encode_bin(Header),
     encode_bin(MA),
     encode_bin(P),
     encode_bin(AP),
     encode_bin(Data)].

prepare(_For, Msg) ->
    Msg.

%% internal
%%

encode_bin(undefined) ->
    <<>>;
encode_bin(Sections) when is_list(Sections) ->
    [amqp10_framing:encode_bin(Section) || Section <- Sections];
encode_bin(Section) ->
    case is_empty(Section) of
        true ->
            <<>>;
        false ->
            amqp10_framing:encode_bin(Section)
    end.

is_empty(#'v1_0.properties'{message_id = undefined,
                            user_id = undefined,
                            to = undefined,
                            % subject = wrap(utf8, RKey),
                            reply_to = undefined,
                            correlation_id = undefined,
                            content_type = undefined,
                            content_encoding = undefined,
                            creation_time = undefined}) ->
    true;
is_empty(#'v1_0.application_properties'{content = []}) ->
    true;
is_empty(#'v1_0.message_annotations'{content = []}) ->
    true;
is_empty(_) ->
    false.


message_annotation(_Key, #msg{message_annotations = undefined},
                  Default) ->
    Default;
message_annotation(Key, #msg{message_annotations =
                             #'v1_0.message_annotations'{content = Content}},
                   Default)
  when is_binary(Key) ->
    %% the section record format really is terrible
    case lists:search(fun ({{symbol, K}, _}) -> K == Key end, Content) of
        {value, {_K, V}} ->
            V;
        false ->
            Default
    end.

message_annotations_as_simple_map(#msg{message_annotations = undefined}) ->
    #{};
message_annotations_as_simple_map(
  #msg{message_annotations = #'v1_0.message_annotations'{content = Content}}) ->
    %% the section record format really is terrible
    lists:foldl(fun ({{symbol, K}, {_T, V}}, Acc)
                      when ?SIMPLE_VALUE(V) ->
                        Acc#{K => V};
                    (_, Acc)->
                        Acc
                end, #{}, Content).

application_properties_as_simple_map(#msg{application_properties = undefined}, M) ->
    M;
application_properties_as_simple_map(
  #msg{application_properties = #'v1_0.application_properties'{content = Content}},
  M) ->
    %% the section record format really is terrible
    lists:foldl(fun
                    ({{utf8, K}, {_T, V}}, Acc)
                      when ?SIMPLE_VALUE(V) ->
                        Acc#{K => V};
                    ({{utf8, K}, undefined}, Acc) ->
                        Acc#{K => undefined};
                    (_, Acc)->
                        Acc
                end, M, Content).

decode([], Acc) ->
    Acc;
decode([#'v1_0.header'{} = H | Rem], Msg) ->
    decode(Rem, Msg#msg{header = H});
decode([#'v1_0.message_annotations'{} = MA | Rem], Msg) ->
    decode(Rem, Msg#msg{message_annotations = MA});
decode([#'v1_0.properties'{} = P | Rem], Msg) ->
    decode(Rem, Msg#msg{properties = P});
decode([#'v1_0.application_properties'{} = AP | Rem], Msg) ->
    decode(Rem, Msg#msg{application_properties = AP});
decode([#'v1_0.delivery_annotations'{} = MA | Rem], Msg) ->
    decode(Rem, Msg#msg{delivery_annotations = MA});
decode([#'v1_0.data'{} = D | Rem], #msg{data = Body} = Msg)
  when is_list(Body) ->
    decode(Rem, Msg#msg{data = Body ++ [D]});
decode([#'v1_0.amqp_sequence'{} = D | Rem], #msg{data = Body} = Msg)
  when is_list(Body) ->
    decode(Rem, Msg#msg{data = Body ++ [D]});
decode([#'v1_0.footer'{} = H | Rem], Msg) ->
    decode(Rem, Msg#msg{footer = H});
decode([#'v1_0.amqp_value'{} = B | Rem], #msg{} = Msg) ->
    %% an amqp value can only be a singleton
    decode(Rem, Msg#msg{data = B}).

add_message_annotations(Anns, MA0) ->
    Content = maps:fold(
                fun
                    (K, {T, V}, Acc) when is_atom(T) ->
                        map_add(symbol, K, T, V, Acc);
                    (K, V, Acc) ->
                        {T, _} = wrap(V),
                        map_add(symbol, K, T, V, Acc)
                end,
                case MA0 of
                    undefined -> [];
                    #'v1_0.message_annotations'{content = C} -> C
                end,
                Anns),
    #'v1_0.message_annotations'{content = Content}.

map_add(_T, _Key, _Type, undefined, Acc) ->
    Acc;
map_add(KeyType, Key, Type, Value, Acc0) ->
    TaggedKey = wrap(KeyType, Key),
    %% TODO: optimise, keydelete always builds a new list even when key is not
    %% found
    Acc = lists:keydelete(TaggedKey, 1, Acc0),
    [{wrap(KeyType, Key), wrap(Type, Value)} | Acc].

wrap(_Type, undefined) ->
    undefined;
wrap(Type, Val) ->
    {Type, Val}.

wrap(undefined) ->
    undefined;
wrap(Val) when is_binary(Val) ->
    %% assume string value
    {utf8, Val};
wrap(Val) when is_integer(Val) ->
    %% assume string value
    {uint, Val}.


key_find(K, [{{_, K}, {_, V}} | _]) ->
    V;
key_find(K, [_ | Rem]) ->
    key_find(K, Rem);
key_find(_K, []) ->
    undefined.

recover_deaths([], Acc) ->
    Acc;
recover_deaths([{map, Kvs} | Rem], Acc) ->
    Queue = key_find(<<"queue">>, Kvs),
    Reason = binary_to_atom(key_find(<<"reason">>, Kvs)),
    DA0 = case key_find(<<"original-expiration">>, Kvs) of
              undefined ->
                  #{};
              Exp ->
                  #{ttl => binary_to_integer(Exp)}
          end,
    RKeys = [RK || {_, RK} <- key_find(<<"routing-keys">>, Kvs)],
    Ts = key_find(<<"time">>, Kvs),
    DA = DA0#{first_time => Ts,
              last_time => Ts},
    recover_deaths(Rem,
                   Acc#{{Queue, Reason} =>
                        #death{anns = DA,
                               exchange = key_find(<<"exchange">>, Kvs),
                               count = key_find(<<"count">>, Kvs),
                               routing_keys = RKeys}}).

essential_properties(#msg{message_annotations = MA} = Msg) ->
    Durable = get_property(durable, Msg),
    Priority = get_property(priority, Msg),
    Timestamp = get_property(timestamp, Msg),
    Ttl = get_property(ttl, Msg),

    Deaths = case message_annotation(<<"x-death">>, Msg, undefined) of
                 {list, DeathMaps}  ->
                     %% TODO: make more correct?
                     Def = {utf8, <<>>},
                     {utf8, FstQ} = message_annotation(<<"x-first-death-queue">>, Msg, Def),
                     {utf8, FstR} = message_annotation(<<"x-first-death-reason">>, Msg, Def),
                     {utf8, LastQ} = message_annotation(<<"x-last-death-queue">>, Msg, Def),
                     {utf8, LastR} = message_annotation(<<"x-last-death-reason">>, Msg, Def),
                     #deaths{first = {FstQ, binary_to_atom(FstR)},
                             last = {LastQ, binary_to_atom(LastR)},
                             records = recover_deaths(DeathMaps, #{})};
                 _ ->
                     undefined
             end,
    Anns = maps_put_falsy(
             durable, Durable,
             maps_put_truthy(
               priority, Priority,
               maps_put_truthy(
                 timestamp, Timestamp,
                 maps_put_truthy(
                   ttl, Ttl,
                   maps_put_truthy(
                     deaths, Deaths,
                     #{}))))),
    case MA of
        undefined ->
            Anns;
        #'v1_0.message_annotations'{content = Content} ->
            lists:foldl(
              fun ({{symbol, <<"x-routing-key">>},
                    {utf8, Key}}, Acc) ->
                      Acc#{routing_keys => [Key]};
                  ({{symbol, <<"x-exchange">>},
                    {utf8, Exchange}}, Acc) ->
                      Acc#{exchange => Exchange};
                  (_, Acc) ->
                      Acc
              end, Anns, Content)
    end.

lists_prepend_t(undefined, L) ->
    L;
lists_prepend_t(Val, L) ->
    [Val | L].

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.