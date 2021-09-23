-module(miner_poc_grpc_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/inet.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").
-include_lib("blockchain/include/blockchain.hrl").
-include("miner_ct_macros.hrl").

-export([
         init_per_suite/1,
         end_per_suite/1,
         init_per_testcase/2,
         end_per_testcase/2,
         all/0
        ]).

-export([
         poc_grpc_test/1

        ]).

%% common test callbacks

all() -> [
          poc_grpc_test
    ].

init_per_suite(Config) ->
    Config.

end_per_suite(Config) ->
    Config.

init_per_testcase(_TestCase, Config0) ->
    Config = miner_ct_utils:init_per_testcase(?MODULE, _TestCase, Config0),
%%    try
    Miners = ?config(miners, Config),
    Addresses = ?config(addresses, Config),

    %% start a local blockchain
    #{public := LocalNodePubKey, secret := LocalNodePrivKey} = libp2p_crypto:generate_keys(
        ecc_compact
    ),
    BaseDir = ?config(base_dir, Config),
    LocalNodeSigFun = libp2p_crypto:mk_sig_fun(LocalNodePrivKey),
    LocalNodeECDHFun = libp2p_crypto:mk_ecdh_fun(LocalNodePrivKey),
    Opts = [
        {key, {LocalNodePubKey, LocalNodeSigFun, LocalNodeECDHFun}},
        {seed_nodes, []},
        {port, 0},
        {num_consensus_members, 7},
        {base_dir, BaseDir}
    ],

    application:set_env(blockchain, base_dir, BaseDir),
    application:set_env(blockchain, peer_cache_timeout, 30000),
    application:set_env(blockchain, peerbook_update_interval, 200),
    application:set_env(blockchain, peerbook_allow_rfc1918, true),
    application:set_env(blockchain, listen_interface, "127.0.0.1"),
    application:set_env(blockchain, max_inbound_connections, length(Miners) * 2),
    application:set_env(blockchain, outbound_gossip_connections, length(Miners) * 2),
    application:set_env(blockchain, sync_cooldown_time, 5),

    {ok, Sup} = blockchain_sup:start_link(Opts),

    %% connect the local node to the slaves
    LocalSwarm = blockchain_swarm:swarm(),
    ok = lists:foreach(
        fun(Node) ->
            ct:pal("connecting local node to ~p", [Node]),
            NodeSwarm = ct_rpc:call(Node, blockchain_swarm, swarm, [], 2000),
            [H | _] = ct_rpc:call(Node, libp2p_swarm, listen_addrs, [NodeSwarm], 2000),
            libp2p_swarm:connect(LocalSwarm, H)
        end,
        Miners
    ),

    %% make sure each node is gossiping with a majority of its peers
    Addrs = ?config(addrs, Config),
    true = miner_ct_utils:wait_until(
             fun() ->
                               try
                                   GossipPeers = blockchain_swarm:gossip_peers(),
                                   case length(GossipPeers) >= (length(Miners) / 2) + 1 of
                                       true ->
                                           true;
                                       false ->
                                           ct:pal("localnode is not connected to enough peers ~p", [GossipPeers]),
%%                                           Swarm = ct_rpc:call(Miner, blockchain_swarm, swarm, [], 500),
                                           lists:foreach(
                                             fun(A) ->
                                                 ct:pal("Connecting localnode to ~p", [A]),
                                                 CRes = libp2p_swarm:connect(LocalSwarm, A),
                                                 ct:pal("Connecting result ~p", [CRes])
                                             end, Addrs),
                                           false
                                   end
                               catch _C:_E ->
                                       false
                               end
             end, 200, 150),

    LocalGossipPeers = blockchain_swarm:gossip_peers(),
    ct:pal("local node connected to ~p peers", [length(LocalGossipPeers)]),

    InitialPaymentTransactions = [ blockchain_txn_coinbase_v1:new(Addr, 5000) || Addr <- Addresses],
    CoinbaseDCTxns = [blockchain_txn_dc_coinbase_v1:new(Addr, 50000000) || Addr <- Addresses],

    %% create a new account to own validators for staking
    #{public := AuxPub} = AuxKeys = libp2p_crypto:generate_keys(ecc_compact),
    AuxAddr = libp2p_crypto:pubkey_to_bin(AuxPub),

    AddGwTxns = [blockchain_txn_gen_validator_v1:new(Addr, Addr, ?bones(10000))
     || Addr <- Addresses] ++ [blockchain_txn_coinbase_v1:new(AuxAddr, ?bones(15000))],

    NumConsensusMembers = ?config(num_consensus_members, Config),
    BlockTime = 12000,

    BatchSize = ?config(batch_size, Config),
    Curve = ?config(dkg_curve, Config),
    Keys = libp2p_crypto:generate_keys(ecc_compact),
    InitialVars = #{?block_time => BlockTime,
                   %% rule out rewards
                   ?election_version => 5,
                   ?election_interval => infinity,
                   ?monthly_reward => ?bones(1000),
                   ?election_restart_interval => 5,
                   ?num_consensus_members => NumConsensusMembers,
                   ?batch_size => BatchSize,
                   ?txn_fees => false,  %% disable fees
                   ?dkg_curve => Curve,
                   ?poc_version => 11,
                  ?securities_percent => 0.34,
                  ?poc_challenge_interval => 15,
                  ?poc_v4_exclusion_cells => 10,
                  ?poc_v4_parent_res => 11,
                  ?poc_v4_prob_bad_rssi => 0.01,
                  ?poc_v4_prob_count_wt => 0.3,
                  ?poc_v4_prob_good_rssi => 1.0,
                  ?poc_v4_prob_no_rssi => 0.5,
                  ?poc_v4_prob_rssi_wt => 0.3,
                  ?poc_v4_prob_time_wt => 0.3,
                  ?poc_v4_randomness_wt => 0.1,
                  ?poc_v4_target_challenge_age => 300,
                  ?poc_v4_target_exclusion_cells => 6000,
                  ?poc_v4_target_prob_edge_wt => 0.2,
                  ?poc_v4_target_prob_score_wt => 0.8,
                  ?poc_v4_target_score_curve => 5,
                  ?poc_target_hex_parent_res => 5,
                  ?poc_v5_target_prob_randomness_wt => 1.0,
                  ?poc_challenge_rate => 1,
                  ?poc_challenger_type => validator,
                  ?data_aggregation_version =>2
    },

    InitialVarsTxn = miner_ct_utils:make_vars(Keys, maps:merge(InitialVars, miner_poc_test_utils:poc_v11_vars())),

    {ok, DKGCompletionNodes} = miner_ct_utils:initial_dkg(Miners, InitialVarsTxn ++ InitialPaymentTransactions ++ CoinbaseDCTxns ++ AddGwTxns,
                                             Addresses, NumConsensusMembers, Curve),
    ct:pal("Nodes which completed the DKG: ~p", [DKGCompletionNodes]),
    %% Get both consensus and non consensus miners
    {ConsensusMiners, NonConsensusMiners} = miner_ct_utils:miners_by_consensus_state(Miners),
    %% integrate genesis block
    _GenesisLoadResults = miner_ct_utils:integrate_genesis_block(hd(DKGCompletionNodes), Miners -- DKGCompletionNodes),
    ct:pal("genesis load results: ~p", [_GenesisLoadResults]),

    %% load the genesis block on the local node
    Blockchain = ct_rpc:call(hd(ConsensusMiners), blockchain_worker, blockchain, []),
    {ok, GenesisBlock} = ct_rpc:call(hd(ConsensusMiners), blockchain, genesis_block, [Blockchain]),
    blockchain_worker:integrate_genesis_block(GenesisBlock),

    %% confirm we have a height of 2
    ok = miner_ct_utils:wait_for_gte(height, Miners, 2),
    true = miner_ct_utils:wait_until_local_height(2),
    ct:pal("local height at 2", []),

    MinerKeys = ?config(keys, Config),
    ct:pal("miner keys ~p", [MinerKeys]),
    [_, {_Payer, {_PayerTCPPort, _PayerUDPPort, _PayerJsonRpcPort}, _PayerECDH, _PayerPubKey, PayerAddr, PayerSigFun},
        {_Owner, {_OwnerTCPPort, _OwnerUDPPort, _OwnerJsonRpcPort}, _OwnerECDH, _OwnerPubKey, OwnerAddr, OwnerSigFun}|_] = MinerKeys,

    ct:pal("owner ~p", [OwnerAddr]),
    ct:pal("Payer ~p", [PayerAddr]),

    %% establish our GRPC connection
%%    {ok, Connection} = grpc_client:connect(tcp, "localhost", 8080),

    [   {sup, Sup},
        {aux_acct, {AuxAddr, AuxKeys}},
        {payer, PayerAddr},
        {payer_sig_fun, PayerSigFun},
        {owner, OwnerAddr},
        {owner_sig_fun, OwnerSigFun},
        {consensus_miners, ConsensusMiners},
        {non_consensus_miners, NonConsensusMiners}
%%        {connection, Connection}
        | Config].
%%    catch
%%        What:Why ->
%%            end_per_testcase(_TestCase, Config),
%%            erlang:What(Why)
%%    end.


end_per_testcase(_TestCase, Config) ->
    miner_ct_utils:end_per_testcase(_TestCase, Config).


poc_grpc_test(Config) ->
    %% mine a block and confirm the POC empheral keys are present
    %% then confirm the assoicated POCs are running and APIs
    Connection = ?config(connection, Config),
    Miners = ?config(miners, Config),
    Miner = hd(?config(non_consensus_miners, Config)),
    PubKeyBinAddrList = ?config(tagged_miner_addresses, Config),

    ct:pal("miner node ~p", [Miner]),

    ConsensusMembers = ?config(consensus_miners, Config),
    ct:pal("consensus members ~p", [ConsensusMembers]),
    Swarm = ct_rpc:call(Miner, blockchain_swarm, swarm, []),
    Chain = ct_rpc:call(Miner, blockchain_worker, blockchain, []),

    {ok, StartHeight} = ct_rpc:call(Miner, blockchain, height, [Chain]),
    ct:pal("start height ~p", [StartHeight]),
    {ok, _Pubkey, _SigFun, _ECDHFun} = ct_rpc:call(Miner, blockchain_swarm, keys, []),

    % All these point are in a line one after the other (except last)
    LatLongs = [
        {{37.780586, -122.469471}, miner_ct_utils:new_random_key_with_sig_fun(ecc_compact)},
        {{37.780959, -122.467496}, miner_ct_utils:new_random_key_with_sig_fun(ecc_compact)},
        {{37.78101, -122.465372}, miner_ct_utils:new_random_key_with_sig_fun(ecc_compact)},
        {{37.781179, -122.463226}, miner_ct_utils:new_random_key_with_sig_fun(ecc_compact)},
        {{37.781281, -122.461038}, miner_ct_utils:new_random_key_with_sig_fun(ecc_compact)},
        {{37.781349, -122.458892}, miner_ct_utils:new_random_key_with_sig_fun(ecc_compact)},
        {{37.781468, -122.456617}, miner_ct_utils:new_random_key_with_sig_fun(ecc_compact)},
        {{37.781637, -122.4543}, miner_ct_utils:new_random_key_with_sig_fun(ecc_compact)}
    ],

    % Add some Gateway at the above lat/longs
    OwnerPubKey = ?config(owner, Config),
    OwnerSigFun = ?config(owner_sig_fun, Config),
    AddGatewayTxs = build_gateways(LatLongs, OwnerPubKey, OwnerSigFun),
    _ = [ct_rpc:call(Miner, blockchain_worker, submit_txn, [AddTxn]) || AddTxn <- AddGatewayTxs],
    ok = miner_ct_utils:wait_for_gte(height, Miners, 3),
    true = miner_ct_utils:wait_until_local_height(3),

    AssertLocaltionTxns = build_asserts(LatLongs, OwnerPubKey, OwnerSigFun),
    _ = [ct_rpc:call(Miner, blockchain_worker, submit_txn, [LocTxn]) || LocTxn <- AssertLocaltionTxns],
    ok = miner_ct_utils:wait_for_gte(height, Miners, 4),
    true = miner_ct_utils:wait_until_local_height(4),

    %% establish streaming grpc connections for each of our fake gateways
    %% we want these connections up before the POCs kick off
    %% so that we can get streamed poc notifications
    GWConns = build_streaming_grpc_conns(LatLongs, ConsensusMembers, PubKeyBinAddrList),

    %% wait until the next block after we asserted our miners
    %% POCs will not kick off until there are asserted GWs
    ok = miner_ct_utils:wait_for_gte(height, Miners, 5),
    true = miner_ct_utils:wait_until_local_height(5),

    %% get the current block
    %% confirm the poc keys are present and in expected quantity
    {ok, Block} =  ct_rpc:call(Miner, blockchain, get_block, [5, Chain]),
    POCKeys = ct_rpc:call(Miner, blockchain_block_v1, poc_keys, [Block]),
    ct:pal("Block POC Keys ~p", [POCKeys]),
    ?assertNotEqual([], POCKeys),

    %% check the number of active POCs running on the CG equals the number of POC keys in the block
    TotalActivePOCs = collect_active_pocs(ConsensusMembers),
    ct:pal("Active POCs: ~p", [TotalActivePOCs]),
    ct:pal("Active POC count: ~p", [length(TotalActivePOCs)]),
    ?assertEqual(length(POCKeys), length(TotalActivePOCs)),

    %% for each active POC, all gateways in the target zone will be sent a notification over grpc informing
    %% them they might be the target
    %% so wait a couple of blocks and then collect and assert the received notifications
    %% we should receive one notification per fake gateway ( 8 )

%%    ok = miner_ct_utils:wait_for_gte(height, Miners, 7),
    TargetNotifications = collect_target_notifications(GWConns),
    ct:pal("Received Target Notifications: ~p", [TargetNotifications]),
%%    ?assertEqual(3, length(TargetNotifications)),

    %% For each target notification, perform a unary grpc request to the challenger
    %% to check if the receiving gateway is actually the target
    TargetResults = collect_target_results(TargetNotifications, PubKeyBinAddrList),
    ct:pal("Check Target Results: ~p", [TargetResults]),
%%    ?assertEqual(3, length(TargetResults)),

    %% filter out all those check target responses where the requesting gateway was not the target
    %% we should be left with the same number of rows as the number of active POCs ( one target per active poc )
    FilteredTargetResults = lists:filter(fun({_OnionKeyHash, _Gateway, _GatewayPrivKey, _GatewaySigFun, _ChallengeMsg, #{target := IsTarget}, _Connection, _BlockHash}) -> IsTarget == true end, TargetResults),
    ct:pal("Filtered Target Results: ~p", [FilteredTargetResults]),
    ?assertEqual(length(TotalActivePOCs), length(FilteredTargetResults)),

    %% filter out all those check target responses where the requesting gateway WAS the target
    %% we will use these as a list of witnesses
    FilteredWitnessResults = lists:filter(fun({_OnionKeyHash, _Gateway, _GatewayPrivKey, _GatewaySigFun, _ChallengeMsg, #{target := IsTarget}, _Connection, _BlockHash}) -> IsTarget == false end, TargetResults),
    ct:pal("Filtered Witness Results: ~p", [FilteredWitnessResults]),

    %%
    %% exercise the grpc receipt and witness reports APIs
    %%

    %% submit a receipt from the challengee/s to the challenger
    %% the challengee will have the challengers grpc routing data
    %% as it is contained in the target notification
    %% potential witnesses in the target zone will also have this data
    %% but actual witnesses ie those who hear the packet may extend outside of this zone
    %% and as such we cannot guarantee that a witness has the challengers routing data
    %% so we need a means for them to firstly know who the challenger is and
    %% secondly to be able to retrive that challenges grpc routing data

    %% NOTE: no need to call miner_lora:send_poc here
    %%       we will just pretend our witnesses heard the packet

    LocalChain = blockchain_worker:blockchain(),
    BroadcastPackets = send_receipts(FilteredTargetResults, LocalChain),
    ct:pal("BroadcastPackets: ~p", [BroadcastPackets]),
    ok = send_witness_reports(BroadcastPackets, FilteredWitnessResults, FilteredTargetResults, LocalChain),

    %% wait for the receipts txn to be absorbed, which will be after the poc expires ( poc expiry set to 4 blocks )
    ok = miner_ct_utils:wait_for_gte(height, ConsensusMembers, 12, all, 120),
    {ok, FinalBlock} =  ct_rpc:call(Miner, blockchain, get_block, [12, Chain]),
    ct:pal("FinalBlock: ~p", [FinalBlock]),

    ReceiptsTxns = find_txns_in_block(FinalBlock, blockchain_txn_poc_receipts_v2),
    ?assertEqual(1, length(ReceiptsTxns)),
    ok.

%% ------------------------------------------------------------------
%% Local Helper functions
%% ------------------------------------------------------------------

build_gateways(LatLongs, Owner, OwnerSigFun) ->
    lists:foldl(
        fun({_LatLong, {_GatewayPrivKey, GatewayPubKey, GatewaySigFun}}, Acc) ->
            % Create a Gateway
            Gateway = libp2p_crypto:pubkey_to_bin(GatewayPubKey),
            AddGatewayTx = blockchain_txn_add_gateway_v1:new(Owner, Gateway),
            SignedOwnerAddGatewayTx = blockchain_txn_add_gateway_v1:sign(AddGatewayTx, OwnerSigFun),
            SignedGatewayAddGatewayTx = blockchain_txn_add_gateway_v1:sign_request(SignedOwnerAddGatewayTx, GatewaySigFun),
            [SignedGatewayAddGatewayTx|Acc]

        end,
        [],
        LatLongs
    ).

build_asserts(LatLongs, Owner, OwnerSigFun) ->
    lists:foldl(
        fun({LatLong, {_GatewayPrivKey, GatewayPubKey, GatewaySigFun}}, Acc) ->
            Gateway = libp2p_crypto:pubkey_to_bin(GatewayPubKey),
            Index = h3:from_geo(LatLong, 13),
            AssertLocationRequestTx = blockchain_txn_assert_location_v1:new(Gateway, Owner, Index, 1),
            PartialAssertLocationTxn = blockchain_txn_assert_location_v1:sign_request(AssertLocationRequestTx, GatewaySigFun),
            SignedAssertLocationTx = blockchain_txn_assert_location_v1:sign(PartialAssertLocationTxn, OwnerSigFun),
            [SignedAssertLocationTx|Acc]
        end,
        [],
        LatLongs
    ).

collect_active_pocs(ConsensusMiners)->
    ActivePOCs = lists:foldl(
        fun(Miner, Acc)->
            POCs = ct_rpc:call(Miner, miner_poc_mgr, active_pocs, []),
            ct:pal("Active POCs ~p", [POCs]),
            ct:pal("~p POCs for miner ~p", [length(POCs), Miner]),
            [POCs | Acc]
        end, [], ConsensusMiners),
    lists:flatten(ActivePOCs).

build_streaming_grpc_conns(LatLongs, ConsensusMembers, MinerPubKeyBins) ->
    lists:foldl(
        fun({_LatLong, {GatewayPrivKey, GatewayPubKey, GatewaySigFun}}, Acc) ->
            %% pick a random CG member to grpc connect this gateway too
            %% As each miner is on the localhost, they will all have a different grpc port
            %% and so as we can determine this, that port will always be equal to the current
            %% libp2p port + 1000, so lets work it out
            ValidatorNode = lists:nth(rand:uniform(length(ConsensusMembers)), ConsensusMembers),
            ValidatorPubKeyBin = miner_ct_utils:node2addr(ValidatorNode, MinerPubKeyBins),
            ValidatorAddr = libp2p_crypto:pubkey_bin_to_p2p(ValidatorPubKeyBin),
            {ok, ValidatorGrpcPort} = ct_rpc:call(ValidatorNode, miner_poc_grpc_utils, p2p_port_to_grpc_port, [ValidatorAddr]),
            {ok, Connection} = grpc_client:connect(tcp, "localhost", ValidatorGrpcPort),
            %% setup a 'streaming poc'  connection to the validator
            {ok, Stream} = grpc_client:new_stream(
                Connection,
                'helium.gateway',
                stream,
                gateway_client_pb
            ),
            GatewayPubKeyBin = libp2p_crypto:pubkey_to_bin(GatewayPubKey),
            Req = #{address => GatewayPubKeyBin, signature => <<>>},
            ReqEncoded = gateway_client_pb:encode_msg(Req, gateway_poc_req_v1_pb),
            Req2 = Req#{signature => GatewaySigFun(ReqEncoded)},
            grpc_client:send(Stream, #{msg => {poc_req, Req2}}),
            [{GatewayPubKey, GatewayPrivKey, GatewaySigFun, Connection, Stream} | Acc]
        end, [], LatLongs).

collect_target_notifications(GWConns) ->
    ct:pal("collecting notifications from ~p", [GWConns]),
    lists:foldl(
        fun({GatewayPubKey, GatewayPrivKey, GatewaySigFun, Connection, Stream}, Acc) ->
            case grpc_client:rcv(Stream, 3000) of
                {error, timeout} ->
                    ct:pal("failed to receive notification for ~p.  Reason ~p", [GatewayPubKey, timeout]),
                    Acc;
                empty -> Acc;
                eof -> Acc;
                {headers, Headers} ->
                    #{<<":status">> := HttpStatus} = Headers,
                    case HttpStatus of
                        <<"200">> ->
                            case grpc_client:rcv(Stream, 5000) of
                                {error, timeout} -> Acc;
                                empty -> Acc;
                                eof -> Acc;
                                {data, Notification} ->
                                    #{
                                            msg := {poc_challenge_resp, ChallengeMsg},
                                            height := NotificationHeight,
                                            signature := ChallengerSig
                                    } = Notification,
                                    [{GatewayPubKey, GatewayPrivKey, GatewaySigFun, ChallengeMsg, NotificationHeight, ChallengerSig, Connection, Stream} | Acc]
                            end;
                        _ ->
                            Acc

                    end
            end
        end, [], GWConns).

collect_target_results(TargetNotifications, PubKeyBinList) ->
    lists:foldl(
        fun({GatewayPubKey, GatewayPrivKey, GatewaySigFun, ChallengeMsg, NotificationHeight, ChallengerSig, Connection, Stream}, Acc) ->
            %% we need to grpc connect to the challenger and check if we are the target
            GatewayPubKeyBin = libp2p_crypto:pubkey_to_bin(GatewayPubKey),
            #{challenger := #{pub_key := ChallengerPubKeyBin}, block_hash := BlockHash, onion_key_hash := OnionKeyHash} = ChallengeMsg,
            ChallengerAddr = libp2p_crypto:pubkey_bin_to_p2p(ChallengerPubKeyBin),
            ChallengerNode = miner_ct_utils:addr2node(ChallengerPubKeyBin, PubKeyBinList),
            {ok, ChallengerGrpcPort} = ct_rpc:call(ChallengerNode, miner_poc_grpc_utils, p2p_port_to_grpc_port, [ChallengerAddr]),
            %%  all nodes are on localhost, each on a diff port, so just connect to the relevant port
            {ok, ChallengerConnection} = grpc_client:connect(tcp, "localhost", ChallengerGrpcPort),
            %% do a unary req to challenger to check if we are the target
            Req = #{
                address => GatewayPubKeyBin,
                challenger => ChallengerPubKeyBin,
                block_hash => BlockHash,
                onion_key_hash => OnionKeyHash,
                height => NotificationHeight,
                notifier => ChallengerPubKeyBin,
                notifier_sig => ChallengerSig,
                challengee_sig => <<>>
            },
            ReqEncoded = gateway_client_pb:encode_msg(Req, gateway_poc_check_challenge_target_req_v1_pb),
            Req2 = Req#{challengee_sig => GatewaySigFun(ReqEncoded)},

            {ok, #{
                    headers := Headers,
                    result := #{
                        msg := {poc_check_target_resp, ChallengeResp},
                        height := _ResponseHeight,
                        signature := _ResponseSig
                    } = Result
                }} = grpc_client:unary(
                    ChallengerConnection,
                    Req2,
                    'helium.gateway',
                    'check_challenge_target',
                    gateway_client_pb,
                    []
                ),
            %% collect the results into a list
            [{OnionKeyHash, GatewayPubKey, GatewayPrivKey, GatewaySigFun, ChallengeMsg, ChallengeResp, Connection, BlockHash} | Acc ]
        end, [], TargetNotifications).


send_receipts(Targets, Chain) ->
    Ledger = blockchain:ledger(Chain),
    lists:foldl(
        fun({OnionKeyHash, GatewayPubKey, GatewayPrivKey, GatewaySigFun, ChallengeMsg, ChallengeResp, Connection, BlockHash}, Acc) ->
            %% for each target, decrypt the onion and lets get the packet and send a receipt
            %% receipts can be sent to our default validator, it will relay it to the required challenger if different
            %% we will also accumulate the next packet here and use this later for the witnesses, fake that they seen it
            #{onion := Onion} = ChallengeResp,
            #{challenger := ChallengerRoute} = ChallengeMsg,
            <<IV:2/binary,
              OnionCompactKey:33/binary,
              Tag:4/binary,
              CipherText/binary>> = Onion,
            ECDHFun = libp2p_crypto:mk_ecdh_fun(GatewayPrivKey),
            case miner_poc_test_utils:decrypt(IV, OnionCompactKey, Tag, CipherText, ECDHFun, BlockHash, Chain) of
                {error, _Reason} ->
                    ct:pal("failed to decrypt for ~p. Reason ~p", [GatewayPubKey, _Reason]),
                    Acc;
                {ok, Data, NextPacket} ->
                    ct:pal("successful decrypt for ~p", [GatewayPubKey]),
                    ct:pal("decrypted data: ~p", [Data]),
                    ct:pal("decrypted next packet: ~p", [NextPacket]),
                    GatewayPubKeyBin = libp2p_crypto:pubkey_to_bin(GatewayPubKey),
                    send_receipt(GatewayPubKeyBin, ChallengerRoute, GatewaySigFun, Data, OnionCompactKey, os:system_time(nanosecond), 0, 0.0, 0.0, 0, [12], Ledger, Connection),
                    [{OnionKeyHash, NextPacket} | Acc]
            end
        end, [], Targets).

send_receipt(GatewayPubKey, ChallengerRoute, GatewaySigFun, Data, OnionCompactKey, Timestamp, RSSI, SNR, Frequency, Channel, DataRate, Ledger, Connection) ->
    ct:pal("sending receipt to gateway ~p", [GatewayPubKey]),
    OnionKeyHash = crypto:hash(sha256, OnionCompactKey),
    Receipt0 = case blockchain:config(?data_aggregation_version, Ledger) of
                   {ok, 1} ->
                       #{gateway=>GatewayPubKey, timestamp=>Timestamp, signal=>RSSI, data=>Data, origin=>p2p, snr=>SNR, frequency=>Frequency, datarate => DataRate};
                   {ok, 2} ->
                       #{gateway=>GatewayPubKey, timestamp=>Timestamp, signal=>RSSI, data=>Data, origin=>p2p, snr=>SNR, frequency=>Frequency, channel=>Channel, datarate=>DataRate};
                   _ ->
                       #{gateway=>GatewayPubKey, timestamp=>Timestamp, signal=>RSSI, data=>Data, origin=>p2p, datarate => DataRate}
               end,
    ct:pal("Receipt0: ~p", [Receipt0]),
    EncodedReceipt = gateway_client_pb:encode_msg(Receipt0, blockchain_poc_receipt_v1_pb),
    Receipt1 = Receipt0#{signature => GatewaySigFun(EncodedReceipt)},
    Req = #{onion_key_hash => OnionKeyHash,  msg => {receipt, Receipt1}},

    {ok, #{
            headers := Headers,
            result := #{
                msg := {success_resp, Resp},
                height := _ResponseHeight,
                signature := _ResponseSig
            } = Result
        }} = grpc_client:unary(
            Connection,
            Req,
            'helium.gateway',
            'send_report',
            gateway_client_pb,
            []
        ),
    ok.


send_witness_reports(BroadcastPackets, Witnesses, Targets, Chain) ->
    %% submit a witness report from each gateway which received a target notification but was not the actual target
    %% we pretent they heard the broadcast, whereas really we just get the packet passed here
    Ledger = blockchain:ledger(Chain),

    TS = os:system_time(nanosecond),
    RSSI = 0,
    SNR = 0.0,
    Frequency = 0.0,
    Channel = 0,
    DataRate = [12],

    lists:foreach(
        fun({OnionKeyHash, GatewayPubKey, _GatewayPrivKey, GatewaySigFun, ChallengeMsg, ChallengeResp, Connection, _BlockHash}) ->
            %% get the packet we pretend we heard and will witness
            ct:pal("finding packet for onionkeyhash ~p", [OnionKeyHash]),
            {_, BroadcastPacket} = lists:keyfind(OnionKeyHash, 1, BroadcastPackets),
            #{challenger := ChallengerRoute} = ChallengeMsg,
            <<_IV:2/binary,
              OnionCompactKey:33/binary,
              Tag:4/binary,
              CipherText/binary>> = BroadcastPacket,
            send_witness_report(crypto:hash(sha256, <<Tag/binary, CipherText/binary>>), GatewayPubKey, GatewaySigFun, OnionCompactKey, os:system_time(nanosecond), RSSI, SNR, Frequency, Channel, DataRate, Ledger, Connection)
        end,
        Witnesses
    ).

send_witness_report(Data, GatewayPubKey, GatewaySigFun, OnionCompactKey, Timestamp, RSSI, SNR, Frequency, Channel, DataRate, Ledger, Connection) ->
    %% witness reports can be sent to our default validator, it will relay it to the required challenger if different
    OnionKeyHash = crypto:hash(sha256, OnionCompactKey),

    %%
    %% construct the witness report
    %%

    GatewayPubKeyBin = libp2p_crypto:pubkey_to_bin(GatewayPubKey),
    Witness0 = case blockchain:config(?data_aggregation_version, Ledger) of
                   {ok, 1} ->
                       #{gateway => GatewayPubKeyBin, timestamp => Timestamp, signal => RSSI, packet_hash => Data, snr => SNR, frequency => Frequency};
                   {ok, 2} ->
                       #{gateway => GatewayPubKeyBin, timestamp => Timestamp, signal => RSSI, packet_hash => Data, snr => SNR, frequency => Frequency, channel => Channel, datarate => DataRate};
                   _ ->
                       #{gateway => GatewayPubKeyBin, timestamp => Timestamp, signal => RSSI, packet_hash => Data}
               end,

    ct:pal("Witness0: ~p", [Witness0]),
    EncodedWitness = gateway_client_pb:encode_msg(Witness0, blockchain_poc_witness_v1_pb),
    Witness1 = Witness0#{signature => GatewaySigFun(EncodedWitness)},
    Req = #{onion_key_hash => OnionKeyHash,  msg => {witness, Witness1}},

    %%
    %% send the report to our validator
    %%
    {ok, #{
            headers := Headers,
            result := #{
                msg := {success_resp, Resp},
                height := _ResponseHeight,
                signature := _ResponseSig
            } = Result
        }} = grpc_client:unary(
            Connection,
            Req,
            'helium.gateway',
            'send_report',
            gateway_client_pb,
            []
        ),
    ok.

find_txns_in_block(Block, TxnType)->
     Ts = blockchain_block:transactions(Block),
     lists:filter(fun(T) -> blockchain_txn:type(T) == TxnType end, Ts).