open Core_kernel
open Async
open Rosetta_lib
open Rosetta_models

(* TODO: Also change this to zero when #5361 finishes *)
let genesis_block_height = Int64.one

module Get_status =
[%graphql
{|
  query {
    genesisBlock {
      stateHash
    }
    bestChain(maxLength: 1) {
      stateHash
      protocolState {
        blockchainState {
          utcDate @bsDecoder(fn: "Int64.of_string")
        }
        consensusState {
          blockHeight @bsDecoder(fn: "Graphql.Decoders.int64")
        }
      }
    }
    daemonStatus {
      chainId
      peers { peerId }
    }
    syncStatus
    initialPeers
  }
|}]

let sync_status_to_string = function
  | `BOOTSTRAP ->
      "Bootstrap"
  | `CATCHUP ->
      "Catchup"
  | `CONNECTING ->
      "Connecting"
  | `LISTENING ->
      "Listening"
  | `OFFLINE ->
      "Offline"
  | `SYNCED ->
      "Synced"

module Get_version =
[%graphql
{|
  query {
    version
    daemonStatus {
      chainId
    }
  }
|}]

module Get_network =
[%graphql
{|
  query {
    daemonStatus {
      chainId
    }
  }
|}]

module Get_network_memoized = struct
  let query =
     Memoize.build @@
     fun ~graphql_uri () -> Graphql.query (Get_network.make ()) graphql_uri

   module Mock = struct
     let query ~graphql_uri:_ =
        Result.return
        @@ object
          method daemonStatus =
            object
              method chainId = "xxxxx"
            end
       end
   end
end


let oldest_block_query =
  Caqti_request.find Caqti_type.unit
    (Caqti_type.tup2 Caqti_type.int64 Caqti_type.string)
    "SELECT height, state_hash FROM blocks ORDER BY timestamp ASC LIMIT 1"

(* TODO: Update this when we have a new chainId *)
let mainnet_chain_id =
  "5f704cc0c82e0ed70e873f0893d7e06f148524e3f0bdae2afb02e7819a0c24d1"

(* TODO: Update this when we have a new chainId *)
let devnet_chain_id =
  "b6ee40d336f4cc3f33c1cc04dee7618eb8e556664c2b2d82ad4676b512a82418"

let network_tag_of_graphql res =
  let equal_chain_id id =
    String.equal (res#daemonStatus)#chainId id
  in
  if equal_chain_id mainnet_chain_id then "mainnet"
  else if equal_chain_id devnet_chain_id then "devnet"
  else "debug"

module Validate_choice = struct
  let build ~chainId =
    object
      method daemonStatus =
        object
          method chainId = chainId
        end
    end

  module Real = struct
    let validate ~network_identifier ~graphql_uri =
      let open Deferred.Result.Let_syntax in
      let%bind gql_response = Get_network_memoized.query ~graphql_uri () in
      let network_tag = network_tag_of_graphql gql_response in
      let requested_tag = network_identifier.Network_identifier.network in
      if not (String.equal requested_tag network_tag) then
        Deferred.Result.fail
          (Errors.create (`Network_doesn't_exist (requested_tag, network_tag)))
      else Deferred.Result.return ()

  end

  module Mock = struct
    let succeed ~network_identifier:_ ~graphql_uri:_ = Result.return ()
  end
end

module List_ = struct
  module Env = struct
    module T (M : Monad_fail.S) = struct
      type 'gql t = unit -> ('gql, Errors.t) M.t
    end

    module Real = T (Deferred.Result)
    module Mock = T (Result)

    let real : graphql_uri:Uri.t -> 'gql Real.t =
      fun ~graphql_uri ->
      Get_network_memoized.query ~graphql_uri
  end

  module Impl (M : Monad_fail.S) = struct
    let handle ~(env : 'gql Env.T(M).t) =
      let open M.Let_syntax in
      let%map res = env () in
      (* HACK: If initialPeers + peers are both empty, assume we're on debug ; otherwise testnet or devnet *)
      let network = network_tag_of_graphql res in
      { Network_list_response.network_identifiers=
          [ { Network_identifier.blockchain= "mina"
            ; network
            ; sub_network_identifier= None } ] }
  end

  module Real = Impl (Deferred.Result)

  let%test_module "list_" =
    ( module struct
      module Mock = Impl (Result)

      let debug_env : 'gql Env.Mock.t =
       fun () -> Result.return @@ Validate_choice.build ~chainId:"0"

      let%test_unit "debug net" =
        Test.assert_ ~f:Network_list_response.to_yojson
          ~actual:(Mock.handle ~env:debug_env)
          ~expected:
            (Result.return
               { Network_list_response.network_identifiers=
                   [ { Network_identifier.blockchain= "mina"
                     ; network= "debug"
                     ; sub_network_identifier= None } ] })

      let devnet_env : 'gql Env.Mock.t =
       fun () ->
        Result.return @@ Validate_choice.build ~chainId:devnet_chain_id

      let%test_unit "devnet net" =
        Test.assert_ ~f:Network_list_response.to_yojson
          ~actual:(Mock.handle ~env:devnet_env)
          ~expected:
            (Result.return
               { Network_list_response.network_identifiers=
                   [ { Network_identifier.blockchain= "mina"
                     ; network= "devnet"
                     ; sub_network_identifier= None } ] })

      let mainnet_env : 'gql Env.Mock.t =
       fun () ->
        Result.return @@ Validate_choice.build ~chainId:mainnet_chain_id

      let%test_unit "mainnet net" =
        Test.assert_ ~f:Network_list_response.to_yojson
          ~actual:(Mock.handle ~env:mainnet_env)
          ~expected:
            (Result.return
               { Network_list_response.network_identifiers=
                   [ { Network_identifier.blockchain= "mina"
                     ; network= "mainnet"
                     ; sub_network_identifier= None } ] })
    end )
end

let dummy_network_request =
  Network_request.create (Network_identifier.create "x" "y")

module Status = struct
  module Env = struct
    module T (M : Monad_fail.S) = struct
      type 'gql t =
        { gql: unit -> ('gql, Errors.t) M.t
        ; db_oldest_block: unit -> (int64 * string, Errors.t) M.t
        ; validate_network_choice: network_identifier:Network_identifier.t -> graphql_uri:Uri.t -> (unit, Errors.t) M.t }
    end

    module Real = T (Deferred.Result)
    module Mock = T (Result)

    let oldest_block_ref = ref None

    let real :
        db:(module Caqti_async.CONNECTION) -> graphql_uri:Uri.t -> 'gql Real.t
        =
     fun ~db ~graphql_uri ->
      let (module Db : Caqti_async.CONNECTION) = db in
      { gql= (fun () -> Graphql.query (Get_status.make ()) graphql_uri)
      ; db_oldest_block=
          (fun () ->
            match !oldest_block_ref with
            | Some oldest_block -> Deferred.Result.return oldest_block
            | None ->
                let%map result =
                  Errors.Lift.sql ~context:"Oldest block query"
                  @@ Db.find oldest_block_query ()
                in
                Result.iter result ~f:(fun oldest_block -> oldest_block_ref := Some oldest_block) ;
                result )
      ; validate_network_choice= Validate_choice.Real.validate }
  end

  module Impl (M : Monad_fail.S) = struct
    let handle ~graphql_uri ~(env : 'gql Env.T(M).t) (network : Network_request.t) =
      let open M.Let_syntax in
      let%bind res = env.gql () in
      let%bind () =
        env.validate_network_choice ~graphql_uri
          ~network_identifier:network.network_identifier
      in
      let%bind latest_block =
        match res#bestChain with
        | None | Some [||] ->
            M.fail (Errors.create `Chain_info_missing)
        | Some chain ->
            M.return (Array.last chain)
      in
      let genesis_block_state_hash = (res#genesisBlock)#stateHash in
      let%map oldest_block = env.db_oldest_block () in
      { Network_status_response.current_block_identifier=
          Block_identifier.create
            ((latest_block#protocolState)#consensusState)#blockHeight
            latest_block#stateHash
      ; current_block_timestamp=
          ((latest_block#protocolState)#blockchainState)#utcDate
      ; genesis_block_identifier=
          Block_identifier.create genesis_block_height genesis_block_state_hash
      ; oldest_block_identifier=
          ( if String.equal (snd oldest_block) genesis_block_state_hash then
            None
          else
            Some
              (Block_identifier.create (fst oldest_block) (snd oldest_block))
          )
      ; peers=
          (let peer_objs = (res#daemonStatus)#peers |> Array.to_list in
           List.map peer_objs ~f:(fun po -> po#peerId |> Peer.create))
      ; sync_status=
          Some
            { Sync_status.current_index=
                Some ((latest_block#protocolState)#consensusState)#blockHeight
            ; target_index= None
            ; stage= Some (sync_status_to_string res#syncStatus)
            ; synced = None
            } }
  end

  module Real = Impl (Deferred.Result)

  let%test_module "status" =
    ( module struct
      module Mock = Impl (Result)

      let build ~best_chain_missing =
        object
          method genesisBlock =
            object
              method stateHash = "GENESIS_HASH"
            end

          method bestChain =
            if best_chain_missing then None
            else
              Some
                [| object
                     method stateHash = "STATE_HASH_TIP"

                     method protocolState =
                       object
                         method blockchainState =
                           object
                             method utcDate = Int64.of_int_exn 1_594_854_566
                           end

                         method consensusState =
                           object
                             method blockHeight = Int64.of_int_exn 4
                           end
                       end
                   end |]

          method daemonStatus =
            object
              method chainId = devnet_chain_id

              method peers =
                [| object
                     method peerId = "dev.o1test.net"
                   end |]
            end

          method syncStatus = `SYNCED
        end

      let no_chain_info_env : 'gql Env.Mock.t =
        { gql= (fun () -> Result.return @@ build ~best_chain_missing:true)
        ; validate_network_choice= Validate_choice.Mock.succeed
        ; db_oldest_block=
            (fun () -> Result.return (Int64.of_int_exn 1, "GENESIS_HASH")) }

      let%test_unit "chain info missing" =
        Test.assert_ ~f:Network_status_response.to_yojson
          ~actual:(Mock.handle ~graphql_uri:(Uri.of_string "https://minaprotocol.com") ~env:no_chain_info_env dummy_network_request)
          ~expected:(Result.fail (Errors.create `Chain_info_missing))

      let oldest_block_is_genesis_env : 'gql Env.Mock.t =
        { gql= (fun () -> Result.return @@ build ~best_chain_missing:false)
        ; validate_network_choice= Validate_choice.Mock.succeed
        ; db_oldest_block=
            (fun () -> Result.return (Int64.of_int_exn 1, "GENESIS_HASH")) }

      let%test_unit "oldest block is genesis" =
        Test.assert_ ~f:Network_status_response.to_yojson
          ~actual:
            (Mock.handle ~graphql_uri:(Uri.of_string "https://minaprotocol.com") ~env:oldest_block_is_genesis_env dummy_network_request)
          ~expected:
            ( Result.return
            @@ { Network_status_response.current_block_identifier=
                   { Block_identifier.index= Int64.of_int_exn 4
                   ; hash= "STATE_HASH_TIP" }
               ; current_block_timestamp= Int64.of_int_exn 1_594_854_566
               ; genesis_block_identifier=
                   { Block_identifier.index= Int64.of_int_exn 1
                   ; hash= "GENESIS_HASH" }
               ; peers= [{Peer.peer_id= "dev.o1test.net"; metadata= None}]
               ; oldest_block_identifier= None
               ; sync_status=
                   Some
                     { Sync_status.current_index= Some (Int64.of_int_exn 4)
                     ; target_index= None
                     ; stage= Some "Synced"
                     ; synced = Some true
                     } } )

      let oldest_block_is_different_env : 'gql Env.Mock.t =
        { gql= (fun () -> Result.return @@ build ~best_chain_missing:false)
        ; validate_network_choice= Validate_choice.Mock.succeed
        ; db_oldest_block=
            (fun () -> Result.return (Int64.of_int_exn 3, "SOME_HASH")) }

      let%test_unit "oldest block is different" =
        Test.assert_ ~f:Network_status_response.to_yojson
          ~actual:
            (Mock.handle ~graphql_uri:(Uri.of_string "https://minaprotocol.com") ~env:oldest_block_is_different_env
               dummy_network_request)
          ~expected:
            ( Result.return
            @@ { Network_status_response.current_block_identifier=
                   { Block_identifier.index= Int64.of_int_exn 4
                   ; hash= "STATE_HASH_TIP" }
               ; current_block_timestamp= Int64.of_int_exn 1_594_854_566
               ; genesis_block_identifier=
                   { Block_identifier.index= Int64.of_int_exn 1
                   ; hash= "GENESIS_HASH" }
               ; peers= [{Peer.peer_id= "dev.o1test.net"; metadata= None}]
               ; oldest_block_identifier=
                   Some
                     { Block_identifier.index= Int64.of_int_exn 3
                     ; hash= "SOME_HASH" }
               ; sync_status=
                   Some
                     { Sync_status.current_index= Some (Int64.of_int_exn 4)
                     ; target_index= None
                     ; stage= Some "Synced"
                     ; synced = Some true
                     } } )
    end )
end

module Options = struct
  module Env = struct
    module T (M : Monad_fail.S) = struct
      type 'gql t =
        { gql: unit -> ('gql, Errors.t) M.t
        ; validate_network_choice: network_identifier:Network_identifier.t -> graphql_uri:Uri.t -> (unit, Errors.t) M.t }
    end

    module Real = T (Deferred.Result)
    module Mock = T (Result)

    let real : graphql_uri:Uri.t -> 'gql Real.t =
     fun ~graphql_uri ->
      { gql= (fun () -> Graphql.query (Get_version.make ()) graphql_uri)
      ; validate_network_choice= Validate_choice.Real.validate }
  end

  module Impl (M : Monad_fail.S) = struct
    let handle ~graphql_uri ~(env : 'gql Env.T(M).t) (network : Network_request.t) =
      let open M.Let_syntax in
      let%bind res = env.gql () in
      let%map () =
        env.validate_network_choice ~graphql_uri
          ~network_identifier:network.network_identifier
      in
      { Network_options_response.version=
          Version.create "1.4.9" (Option.value ~default:"unknown" res#version)
      ; allow=
          { Allow.operation_statuses= Lazy.force Operation_statuses.all
          ; operation_types= Lazy.force Operation_types.all
          ; errors= Lazy.force Errors.all_errors
          ; historical_balance_lookup=
              true
              (* TODO: #6872 We should expose info for the timestamp_start_index via GraphQL then consume it here *)
          ; timestamp_start_index=
              None
              (* If we implement the /call endpoint we'll need to list its supported methods here *)
          ; call_methods= []
          ; balance_exemptions= []
          ; mempool_coins= false } }
  end

  module Real = Impl (Deferred.Result)

  let%test_module "options" =
    ( module struct
      module Mock = Impl (Result)

      let env : 'gql Env.Mock.t =
        { gql=
            (fun () ->
              Result.return
              @@ object
                   method version = Some "v1.0"
                 end )
        ; validate_network_choice= Validate_choice.Mock.succeed }

      let%test_unit "options succeeds" =
        Test.assert_ ~f:Network_options_response.to_yojson
          ~actual:(Mock.handle ~graphql_uri:(Uri.of_string "https://minaprotocol.com") ~env dummy_network_request)
          ~expected:
            ( Result.return
            @@ { Network_options_response.version= Version.create "1.4.9" "v1.0"
               ; allow=
                   { Allow.operation_statuses= Lazy.force Operation_statuses.all
                   ; operation_types= Lazy.force Operation_types.all
                   ; errors= Lazy.force Errors.all_errors
                   ; historical_balance_lookup= true
                   ; timestamp_start_index= None
                   ; call_methods= []
                   ; balance_exemptions= []
                   ; mempool_coins= false } } )
    end )
end

let router ~graphql_uri ~logger ~with_db (route : string list) body =
  let open Async.Deferred.Result.Let_syntax in
  [%log debug] "Handling /network/ $route"
    ~metadata:[("route", `List (List.map route ~f:(fun s -> `String s)))] ;
  match route with
  | ["list"] ->
      let%bind _meta =
        Errors.Lift.parse ~context:"Request" @@ Metadata_request.of_yojson body
        |> Errors.Lift.wrap
      in
      let%map res =
        List_.Real.handle ~env:(List_.Env.real ~graphql_uri)
        |> Errors.Lift.wrap
      in
      Network_list_response.to_yojson res
  | ["status"] ->
      with_db (fun ~db ->
          let%bind network =
            Errors.Lift.parse ~context:"Request"
            @@ Network_request.of_yojson body
            |> Errors.Lift.wrap
          in
          let%map res =
            Status.Real.handle ~graphql_uri ~env:(Status.Env.real ~graphql_uri ~db) network
            |> Errors.Lift.wrap
          in
          Network_status_response.to_yojson res )
  | ["options"] ->
      let%bind network =
        Errors.Lift.parse ~context:"Request" @@ Network_request.of_yojson body
        |> Errors.Lift.wrap
      in
      let%map res =
        Options.Real.handle ~graphql_uri ~env:(Options.Env.real ~graphql_uri) network
        |> Errors.Lift.wrap
      in
      Network_options_response.to_yojson res
  | _ ->
      Deferred.Result.fail `Page_not_found
