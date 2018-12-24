(**********************************************************************)
(* Equations                                                          *)
(* Copyright (c) 2009-2017 Matthieu Sozeau <matthieu.sozeau@inria.fr> *)
(**********************************************************************)
(* This file is distributed under the terms of the                    *)
(* GNU Lesser General Public License Version 2.1                      *)
(**********************************************************************)

(** Principles derived from equation definitions. *)

open Constr
open Names
open Vars
open Equations_common
open Syntax
open Context_map
open Splitting
open Principles_proofs

type statement = EConstr.constr * EConstr.types option
type statements = statement list

type recursive = bool

type node_kind =
  | Regular
  | Refine
  | Where
  | Nested of recursive

let kind_of_prog p =
  match p.program_rec with
  | Some (Structural (NestedOn (Some _))) -> Nested true
  | Some (Structural (NestedOn None)) -> Nested false
  | _ -> Regular

let regular_or_nested = function
  | Regular | Nested _ -> true
  | _ -> false

let regular_or_nested_rec = function
  | Regular -> true
  | Nested r -> r
  | _ -> false

let pi1 (x,_,_) = x
let pi2 (_,y,_) = y
let pi3 (_,_,z) = z

let match_arguments sigma l l' =
  let rec aux i =
    if i < Array.length l' then
      if i < Array.length l then
        if EConstr.eq_constr sigma l.(i) l'.(i) then
          i :: aux (succ i)
        else aux (succ i)
      else aux (succ i)
    else [i]
  in aux 0

let filter_arguments f l =
  let rec aux i f l =
    match f, l with
    | n :: f', a :: l' ->
       if i < n then aux (succ i) f l'
       else if i = n then
         a :: aux (succ i) f' l'
       else assert false
    | _, _ -> l
  in aux 0 f l

module CMap = Map.Make(Constr)

let clean_rec_calls sigma (hyps, c) =
  let open Context.Rel.Declaration in
  (* Remove duplicate induction hypotheses under contexts *)
  let under_context, hyps =
    CMap.partition (fun ty n -> Constr.isProd ty || Constr.isLetIn ty) hyps
  in
  let hyps =
    CMap.fold (fun ty n hyps ->
      let ctx, concl = Term.decompose_prod_assum ty in
      let len = List.length ctx in
      if noccur_between 1 len concl then
          if CMap.mem (lift (-len) concl) hyps then hyps
          else CMap.add ty n hyps
        else CMap.add ty n hyps)
      under_context hyps
  in
  (* Sort by occurrence *)
  let elems = List.sort (fun x y -> Int.compare (snd x) (snd y)) (CMap.bindings hyps) in
  let (size, ctx) =
    List.fold_left (fun (n, acc) (ty, _) ->
    (succ n, LocalAssum (Name (Id.of_string "Hind"), EConstr.Vars.lift n (EConstr.of_constr ty)) :: acc))
    (0, []) elems
  in
  (ctx, size, EConstr.Vars.lift size (EConstr.of_constr c))

let head c = fst (Constr.decompose_app c)

let is_applied_to_structarg f is_rec lenargs =
  match is_rec with
  | Some (Guarded ids) -> begin
     try
       let kind =
         CList.find_map (fun (f', k) -> if Id.equal f f' then Some k else None) ids
       in
       match kind with
       | MutualOn (idx,_) | NestedOn (Some (idx,_)) -> Some (lenargs > idx)
       | NestedOn None -> Some true
     with Not_found -> None
    end
  | _ -> None

let is_user_obl sigma user_obls f =
  match EConstr.kind sigma f with
  | Const (c, u) -> Id.Set.mem (Label.to_id (Constant.label c)) user_obls
  | _ -> false

let cmap_map f c =
  CMap.fold (fun ty n hyps -> CMap.add (f ty) n hyps) c CMap.empty

let cmap_union g h =
  CMap.merge (fun ty n m ->
    match n, m with
    | Some n, Some m -> Some (min n m)
    | Some _, None -> n
    | None, Some _ -> m
    | None, None -> None) g h

let cmap_add ty n h =
  cmap_union (CMap.singleton ty n) h


let subst_telescope cstr ctx =
  let (_, ctx') = List.fold_left
    (fun (k, ctx') decl ->
      (succ k, (Context.Rel.Declaration.map_constr (substnl [cstr] k) decl) :: ctx'))
    (0, []) ctx
  in List.rev ctx'

let substitute_args args ctx =
  let open Context.Rel.Declaration in
  let rec aux ctx args =
    match args, ctx with
    | a :: args, LocalAssum _ :: ctx -> aux (subst_telescope a ctx) args
    | _ :: _, LocalDef (na, b, t) :: ctx -> aux (subst_telescope b ctx) args
    | [], ctx -> List.rev ctx
    | _, [] -> assert false
  in aux (List.rev ctx) args

let find_rec_call is_rec sigma protos f args =
  let fm ((f',filter), alias, idx, sign, arity) =
    let f', args' = Termops.decompose_app_vect sigma f' in
    let f' = EConstr.Unsafe.to_constr f' in
    let args' = Array.map EConstr.Unsafe.to_constr args' in
    let nhyps = Context.Rel.nhyps sign + Array.length args' in
    if Constr.equal f' f then
      let f' = fst (Constr.destConst f') in
      match is_applied_to_structarg (Names.Label.to_id (Names.Constant.label f')) is_rec
              (List.length args) with
      | Some true | None ->
        let sign, args =
          if nhyps <= List.length args then [], CList.chop nhyps args
          else
            let sign = List.map EConstr.Unsafe.to_rel_decl sign in
            let _, substargs = CList.chop (Array.length args') args in
            let sign = substitute_args substargs sign in
            let signlen = List.length sign in
            sign, (List.map (lift signlen) args @ Context.Rel.to_extended_list mkRel 0 sign, [])
        in
        Some (idx, arity, filter, sign, args)
      | Some false -> None
    else
      match alias with
      | Some (f',argsf) ->
        let f', args' = Termops.decompose_app_vect sigma f' in
        let f' = EConstr.Unsafe.to_constr f' in
        if Constr.equal (head f') f then
          Some (idx, arity, argsf, [], (args, []))
        else None
      | None -> None
  in
  try Some (CList.find_map fm protos)
  with Not_found -> None

let abstract_rec_calls sigma user_obls ?(do_subst=true) is_rec len protos c =
  let proto_fs = List.map (fun ((f,args), _, _, _, _) -> f) protos in
  let occ = ref 0 in
  let rec aux n env hyps c =
    let open Constr in
    match kind c with
    | Lambda (na,t,b) ->
      let hyps',b' = aux (succ n) ((na,None,t) :: env) CMap.empty b in
      let hyps' = cmap_map (fun ty -> mkProd (na, t, ty)) hyps' in
        cmap_union hyps hyps', c

    (* | Cast (_, _, f) when is_comp f -> aux n f *)

    | LetIn (na,b,t,body) ->
      let hyps',b' = aux n env hyps b in
      let hyps'',body' = aux (succ n) ((na,Some b,t) :: env) CMap.empty body in
        cmap_union hyps' (cmap_map (fun ty -> Constr.mkLetIn (na,b,t,ty)) hyps''), c

    | Prod (na, d, c) when noccurn 1 c  ->
      let hyps',d' = aux n env hyps d in
      let hyps'',c' = aux n env hyps' (subst1 mkProp c) in
        hyps'', mkProd (na, d', lift 1 c')

    | Case (ci, p, c, brs) ->
      let hyps', c' = aux n env hyps c in
      let hyps' = Array.fold_left (fun hyps br -> fst (aux n env hyps br)) hyps' brs in
      let case' = mkCase (ci, p, c', brs) in
        hyps', EConstr.Unsafe.to_constr (EConstr.Vars.substnl proto_fs (succ len) (EConstr.of_constr case'))

    | Proj (p, c) ->
      let hyps', c' = aux n env hyps c in
        hyps', mkProj (p, c')

    | _ ->
      let f', args = decompose_appvect c in
      if not (is_user_obl sigma user_obls (EConstr.of_constr f')) then
        let hyps =
          (* TODO: use filter here *)
          Array.fold_left (fun hyps arg -> let hyps', arg' = aux n env hyps arg in
                            hyps')
            hyps args
        in
        let args = Array.to_list args in
        (match find_rec_call is_rec sigma protos f' args with
         | Some (i, arity, filter, sign, (args', rest)) ->
           let fargs' = filter_arguments filter args' in
           let result = Termops.it_mkLambda_or_LetIn (mkApp (f', CArray.of_list args')) sign in
           let hyp =
             Term.it_mkProd_or_LetIn
               (Constr.mkApp (mkApp (mkRel (i + 1 + len + n + List.length sign), Array.of_list fargs'),
                              [| Term.applistc (lift (List.length sign) result)
                                   (Context.Rel.to_extended_list mkRel 0 sign) |]))
               sign
           in
           let hyps = cmap_add hyp !occ hyps in
           let () = incr occ in
           hyps, Term.applist (result, rest)
         | None -> hyps, mkApp (f', Array.of_list args))
      else
        let c' =
          if do_subst then (EConstr.Unsafe.to_constr (EConstr.Vars.substnl proto_fs (len + n) (EConstr.of_constr c)))
          else c
        in hyps, c'
  in clean_rec_calls sigma (aux 0 [] CMap.empty (EConstr.Unsafe.to_constr c))

open EConstr

let subst_app sigma f fn c =
  let rec aux n c =
    match kind sigma c with
    | App (f', args) when eq_constr sigma f f' ->
      let args' = Array.map (map_with_binders sigma succ aux n) args in
      fn n f' args'
    | Var _ when eq_constr sigma f c ->
       fn n c [||]
    | _ -> map_with_binders sigma succ aux n c
  in aux 0 c

let subst_comp_proj sigma f proj c =
  subst_app sigma proj (fun n x args ->
    mkApp (f, if Array.length args > 0 then Array.sub args 0 (Array.length args - 1) else args))
    c

(* Substitute occurrences of [proj] by [f] in the splitting. *)
let subst_comp_proj_split sigma f proj s =
  map_split (subst_comp_proj sigma f proj) s

let is_ind_assum sigma ind b =
  let _, concl = decompose_prod_assum sigma b in
  let t, _ = decompose_app sigma concl in
  if isInd sigma t then
    let (ind', _), _ = destInd sigma t in
    MutInd.equal ind' ind
  else false

let clear_ind_assums sigma ind ctx =
  let rec clear_assums c =
    match kind sigma c with
    | Prod (na, b, c) ->
       if is_ind_assum sigma ind b then
         (assert(not (Termops.dependent sigma (mkRel 1) c));
          clear_assums (Vars.subst1 mkProp c))
       else mkProd (na, b, clear_assums c)
    | LetIn (na, b, t, c) ->
        mkLetIn (na, b, t, clear_assums c)
    | _ -> c
  in map_rel_context clear_assums ctx

let type_of_rel t ctx =
  match Constr.kind t with
  | Rel k -> Vars.lift k (get_type (List.nth ctx (pred k)))
  | c -> mkProp

open Vars

let compute_elim_type env evd user_obls is_rec protos k leninds
                      ind_stmts all_stmts sign app elimty =
  let ctx, arity = decompose_prod_assum !evd elimty in
  let lenrealinds =
    List.length (List.filter (fun (_, (_,_,_,_,_,_,_,(kind,_)),_) -> regular_or_nested_rec kind) ind_stmts) in
  let newctx =
    if lenrealinds == 1 then CList.skipn (List.length sign + 2) ctx
    else ctx
  in
  (* Assumes non-dep mutual eliminator of the graph *)
  let newarity =
    if lenrealinds == 1 then
      it_mkProd_or_LetIn (Vars.substl [mkProp; app] arity) sign
    else
      let clean_one a sign fn =
        let ctx, concl = decompose_prod_assum !evd a in
        let newctx = CList.skipn 2 ctx in
        let newconcl = Vars.substl [mkProp; mkApp (fn, extended_rel_vect 0 sign)] concl in
        it_mkProd_or_LetIn newconcl newctx
      in
      let rec aux arity ind_stmts =
        match kind !evd arity, ind_stmts with
        | _, (i, ((fn, _), _, _, sign, ar, _, _, ((Where | Refine), cut)), _) :: stmts ->
           aux arity stmts
        | App (conj, [| arity; rest |]),
          (i, ((fn, _), _, _, sign, ar, _, _, (refine, cut)), _) :: stmts ->
           mkApp (conj, [| clean_one arity sign fn ; aux rest stmts |])
        | _, (i, ((fn, _), _, _, sign, ar, _, _, _), _) :: stmts ->
           aux (clean_one arity sign fn) stmts
        | _, [] -> arity
      in aux arity ind_stmts
  in
  let newctx' = clear_ind_assums !evd k newctx in
  if leninds == 1 then List.length newctx', it_mkProd_or_LetIn newarity newctx' else
  let sort = fresh_logic_sort evd in
  let methods, preds = CList.chop (List.length newctx - leninds) newctx' in
  let ppred, preds = CList.sep_last preds in
  let newpredfn i d (idx, (f', alias, path, sign, arity, pats, args, (refine, cut)), _) =
    if refine != Refine then d else
    let (n, b, t) = to_tuple d in
    let signlen = List.length sign in
    let ctx = of_tuple (Anonymous, None, arity) :: sign in
    let app =
      let argsinfo =
        CList.map_i
          (fun i (c, arg) ->
           let idx = signlen - arg + 1 in (* lift 1, over return value *)
           let ty = Vars.lift (idx (* 1 for return value *))
                         (get_type (List.nth sign (pred (pred idx))))
           in
           (idx, ty, lift 1 c, mkRel idx))
          0 args
      in
      let lenargs = List.length argsinfo in
      let transport = get_efresh logic_eq_case evd in
      let transport ty x y eq c cty =
        mkApp (transport,
               [| ty; x;
                  mkLambda (Name (Id.of_string "abs"), ty,
                            Termops.replace_term !evd (Vars.lift 1 x) (mkRel 1) (Vars.lift 1 cty));
                  c; y; eq (* equality *) |])
      in
      let pargs, subst =
        match argsinfo with
        | [] -> List.map (lift (lenargs+1)) pats, []
        | (i, ty, c, rel) :: [] ->
           List.fold_right
           (fun t (pargs, subst) ->
            let _idx = i + 2 * lenargs in
            let rel = lift lenargs rel in
            let tty = lift (lenargs+1) (type_of_rel (to_constr !evd t) sign) in
            if Termops.dependent !evd rel tty then
              let tr =
                if isRel !evd c then lift (lenargs+1) t
                else
                  transport (lift lenargs ty) rel (lift lenargs c)
                            (mkRel 1) (lift (lenargs+1) (t)) tty
              in
              let t' =
                if isRel !evd c then lift (lenargs+3) (t)
                else transport (lift (lenargs+2) ty)
                               (lift 2 rel)
                               (mkRel 2)
                               (mkRel 1) (lift (lenargs+3) (t)) (lift 2 tty)
              in (tr :: pargs, (rel, t') :: subst)
            else (* for equalities + return value *)
              let t' = lift (lenargs+1) (t) in
              let t' = Termops.replace_term !evd (lift (lenargs) c) rel t' in
              (t' :: pargs, subst)) pats ([], [])
        | _ -> assert false
      in
      let result, _ =
        List.fold_left
        (fun (acc, pred) (i, ty, c, rel) ->
         let idx = i + 2 * lenargs in
         if Termops.dependent !evd (mkRel idx) pred then
           let eqty =
             mkEq env evd (lift (lenargs+1) ty) (mkRel 1)
                  (lift (lenargs+1) rel)
           in
           let pred' =
             List.fold_left
               (fun acc (t, tr) -> Termops.replace_term !evd t tr acc)
               (lift 1 (Termops.replace_term !evd (mkRel idx) (mkRel 1) pred))
               subst
           in
           let transportd = get_efresh logic_eq_elim evd in
           let app =
             mkApp (transportd,
                    [| lift lenargs ty; lift lenargs rel;
                       mkLambda (Name (Id.of_string "refine"), lift lenargs ty,
                                 mkLambda (Name (Id.of_string "refine_eq"), eqty, pred'));
                       acc; (lift lenargs c); mkRel 1 (* equality *) |])
           in (app, subst1 c pred)
         else (acc, subst1 c pred))
        (mkRel (succ lenargs), lift (succ (lenargs * 2)) arity)
        argsinfo
      in
      let ppath = (* The preceding P *)
        match path with
        | [] -> assert false
        | ev :: path ->
           let res =
             list_find_map_i (fun i' (_, (_, _, path', _, _, _, _, _), _) ->
                              if eq_path path' path then Some (idx + 1 - i')
                              else None) 1 ind_stmts
           in match res with None -> assert false | Some i -> i
      in
      let papp =
        applistc (lift (succ signlen + lenargs) (mkRel ppath))
                 pargs
      in
      let papp = applistc papp [result] in
      let refeqs = List.map (fun (i, ty, c, rel) -> mkEq env evd ty c rel) argsinfo in
      let app c = List.fold_right
                  (fun c acc ->
                   mkProd (Name (Id.of_string "Heq"), c, acc))
                  refeqs c
      in
      let indhyps =
        List.concat
        (List.map (fun (c, _) ->
              let hyps, hypslen, c' =
                abstract_rec_calls !evd user_obls ~do_subst:false
                   is_rec signlen protos (Reductionops.nf_beta env !evd (lift 1 c))
              in
              let lifthyps = lift_rel_contextn (signlen + 2) (- (pred i)) hyps in
                lifthyps) args)
      in
        it_mkLambda_or_LetIn
          (app (it_mkProd_or_clean env !evd (lift (List.length indhyps) papp)
                                   (lift_rel_context lenargs indhyps)))
          ctx
    in
    let ty = it_mkProd_or_LetIn sort ctx in
    of_tuple (n, Some app, ty)
  in
  let newpreds = CList.map2_i newpredfn 1 preds (List.rev (List.tl ind_stmts)) in
  let skipped, methods' = (* Skip the indirection methods due to refinements,
                              as they are trivially provable *)
    let rec aux stmts meths n meths' =
      match stmts, meths with
      | (Refine, _, _, _) :: stmts, decl :: decls ->
         aux stmts (Equations_common.subst_telescope mkProp decls) (succ n) meths'
      | (_, _, _, None) :: stmts, decls -> (* Empty node, no constructor *)
         aux stmts decls n meths'
      | (_, _, _, _) :: stmts, decl :: decls ->
         aux stmts decls n (decl :: meths')
      | [], [] -> n, meths'
      | [], decls -> n, List.rev decls @ meths'
      | (_, _, _, Some _) :: stmts, [] ->
        anomaly Pp.(str"More statemsnts than declarations while computing eliminator")
    in aux all_stmts (List.rev methods) 0 []
  in
  let ctx = methods' @ newpreds @ [ppred] in
  let elimty = it_mkProd_or_LetIn (lift (-skipped) newarity) ctx in
  let undefpreds = List.length (List.filter (fun decl -> Option.is_empty (get_value decl)) newpreds) in
  let nargs = List.length methods' + undefpreds + 1 in
  nargs, elimty

let replace_vars_context inst ctx =
  List.fold_right
    (fun decl (k, acc) ->
      let decl' = map_rel_declaration (substn_vars k inst) decl in
      (succ k, decl' :: acc))
    ctx (1, [])

let pr_where env sigma ctx ({where_prob; where_term; where_type; where_splitting} as w) =
  let open Pp in
  let envc = Environ.push_rel_context ctx env in
  Printer.pr_econstr_env envc sigma where_term ++ fnl () ++
    str"where " ++ Names.Id.print (where_id w) ++ str" : " ++
    Printer.pr_econstr_env envc sigma where_type ++
    str" := " ++ fnl () ++
    Context_map.pr_context_map env sigma where_prob ++ fnl () ++
    pr_splitting env sigma (Lazy.force where_splitting)

let where_instance w =
  List.map (fun w -> w.where_term) w

let arguments sigma c = snd (Termops.decompose_app_vect sigma c)

let unfold_constr sigma c =
  to82 (Tactics.unfold_in_concl [(Locus.OnlyOccurrences [1], EvalConstRef (fst (destConst sigma c)))])

let extend_prob_ctx delta (ctx, pats, ctx') =
  (delta @ ctx, Context_map.lift_pats (List.length delta) pats, ctx')

let map_proto evd recarg f ty =
  match recarg with
  | Some recarg ->
     let lctx, ty' = decompose_prod_assum evd ty in
     let app =
       let args = Termops.rel_list 0 (List.length lctx) in
       let before, after =
         if recarg == -1 then CList.drop_last args, []
         else let bf, after = CList.chop (pred recarg) args in
              bf, List.tl after
       in
       applistc (lift (List.length lctx) f) (before @ after)
     in
     it_mkLambda_or_LetIn app lctx
  | None -> f

type rec_subst = (Names.Id.t * (int option * EConstr.constr)) list

let cut_problem evd s ctx' =
  let pats, cutctx', _, _ =
    (* From Γ |- ps, prec, ps' : Δ, rec, Δ', build
       Γ |- ps, ps' : Δ, Δ' *)
    List.fold_right (fun d (pats, ctx', i, subs) ->
    let (n, b, t) = to_tuple d in
    match n with
    | Name n when List.mem_assoc n s ->
       let recarg, term = List.assoc n s in
       let term = map_proto evd recarg term t in
       (pats, ctx', pred i, term :: subs)
    | _ ->
       let decl = of_tuple (n, Option.map (substl subs) b, substl subs t) in
       (i :: pats, decl :: ctx',
        pred i, mkRel 1 :: List.map (lift 1) subs))
    ctx' ([], [], List.length ctx', [])
  in (ctx', List.map (fun i -> Context_map.PRel i) pats, cutctx')

let subst_rec env evd cutprob s (ctx, p, _ as lhs) =
  let subst =
    List.fold_left (fun (ctx, pats, ctx' as lhs') (id, (recarg, b)) ->
    try let rel, _, ty = Termops.lookup_rel_id id ctx in
        let fK = map_proto evd recarg (mapping_constr evd lhs b) (lift rel ty) in
        let substf = single_subst env evd rel (PInac fK) ctx
        (* ctx[n := f] |- _ : ctx *) in
        compose_subst env ~sigma:evd substf lhs'
    with Not_found (* lookup *) -> lhs') (id_subst ctx) s
  in
  let csubst =
    compose_subst env ~sigma:evd
    (compose_subst env ~sigma:evd subst lhs) cutprob
  in subst, csubst

let subst_rec_split env evd p f path prob s split =
  let where_map = ref Evar.Map.empty in
  let evd = ref evd in
  let cut_problem s ctx' = cut_problem !evd s ctx' in
  let subst_rec cutprob s lhs = subst_rec env !evd cutprob s lhs in
  let rec aux cutprob s p f path = function
    | Compute ((ctx,pats,del as lhs), where, ty, c) ->
       let subst, lhs' = subst_rec cutprob s lhs in
       let progctx = (extend_prob_ctx (where_context where) lhs) in
       let substprog, _ = subst_rec cutprob s progctx in
       let islogical = List.exists (fun (id, (recarg, f)) -> Option.has_some recarg) s in
       let subst_where ({where_program; where_path; where_orig;
                         where_prob; where_arity; where_term;
                         where_type; where_splitting} as w) (subst_wheres, wheres) =
         let wcontext = where_context subst_wheres in
         let wsubst = lift_subst env !evd subst wcontext in
         let where_term = mapping_constr !evd wsubst where_term in
         let where_type = mapping_constr !evd subst where_type in
         let where_program', s, extpatlen =
           (* Should be the number of extra patterns for the whole fix block *)
           match where_program.program_rec with
           | Some (Structural ids) ->
             let _recarg = match ids with
               | NestedOn None -> None
               | NestedOn (Some (x, _)) -> Some x
               | MutualOn (x, _) -> Some x
             in
             let s = ((where_program.program_id, (None,
                 lift (List.length (pi1 where_prob) - List.length ctx) w.where_term)) :: s) in
             let where_program = { where_program with program_rec = None } in
             where_program, s, 0
           | _ -> where_program, s, 0
         in
         let cutprob = cut_problem s (pi1 where_prob) in
         let wsubst, _ = subst_rec where_prob s where_prob in
         let where_prob = id_subst (pi3 cutprob) in

         (* let where_impl, args = decompose_app !evd where_term in *)
         let where_term' =
           (* Lives in where_prob *)
           (lift (List.length (pi1 cutprob) - List.length ctx) w.where_term) in

         let where_arity = mapping_constr !evd wsubst where_arity in

         let where_program' =
           { where_program' with
             program_sign = pi3 cutprob;
             program_arity = mapping_constr !evd wsubst where_program'.program_arity }
         in
         let where_splitting =
           aux cutprob s where_program' where_term'
             where_path (Lazy.force where_splitting)
         in
         let where_term, where_path =
           if islogical then
             let evm, ev = (* We create an evar here for the new where implementation *)
               Equations_common.new_evar env !evd where_type
             in
             let () = evd := evm in
             let evk = fst (destEvar !evd ev) in
             let id = Nameops.add_suffix (where_id w) "_unfold_eq" in
             let () = where_map := Evar.Map.add evk (where_term (* substituted *), id, where_splitting) !where_map in
             (* msg_debug (str"At where in update_split, calling recursively with term" ++ *)
             (*              pr_constr w.where_term ++ str " associated to " ++ int (Evar.repr evk)); *)
             (applist (ev, extended_rel_list 0 (pi1 lhs')), Evar evk :: List.tl where_path)
           else (where_term, where_path)
         in
         let subst_where =
           {where_program = where_program';
            where_program_orig = where_program;
            where_path; where_orig; where_prob = where_prob;
            where_context_length = List.length (pi1 lhs') + extpatlen;
            where_arity; where_term;
            where_type; where_splitting = Lazy.from_val where_splitting }
         in (subst_where :: subst_wheres, w :: wheres)
       in
       let where', _ = List.fold_right subst_where where ([], []) in
       Compute (lhs', where', mapping_constr !evd substprog ty,
                mapping_rhs !evd substprog c)

    | Split (lhs, n, ty, cs) ->
       let subst, lhs' = subst_rec cutprob s lhs in
       let n' = destRel !evd (mapping_constr !evd subst (mkRel n)) in
       Split (lhs', n', mapping_constr !evd subst ty,
              Array.map (Option.map (aux cutprob s p f path)) cs)

    | Mapping (lhs, c) ->
       let subst, lhs' = subst_rec cutprob s lhs in
       Mapping (lhs', aux cutprob s p f path c)

    | RecValid (id, Valid (ctx, ty, args, tac, view,
                           [goal, args', newprob, invsubst, rest])) ->
       let recarg, proj = match p.program_rec with
       | Some (WellFounded (_, _, r)) ->
          (match r with
           | (loc, id) -> (Some (-1)), mkVar id)
       | _ -> anomaly Pp.(str"Not looking at the right program")
       in
       (* let rest = subst_comp_proj_split !evd f proj rest in *)
       let s = (id, (recarg, lift 1 f)) :: s in
       let cutprob = (cut_problem s (pi1 newprob)) in
       let rest = aux cutprob s p f (Ident id :: path) rest in

              (* let cutprob = (cut_problem s (pi1 subst)) in
               * let _subst, subst =
               *   try subst_rec cutprob s subst
               *   with e -> assert false in
               * (\* let invsubst = Option.map (fun x -> snd (subst_rec (cut_problem s (pi3 x)) s x)) invsubst in *\)
               *     (g, l, subst, invsubst,  *)
       (match invsubst with
        | Some s -> Mapping (s, rest)
        | None -> rest)

    | RecValid (id, c) ->
       RecValid (id, aux cutprob s p f (Ident id :: path) c)

    | Refined (lhs, info, sp) ->
       let (id, c, cty), ty, arg, ev, (fev, args), revctx, newprob, newty =
         info.refined_obj, info.refined_rettyp,
         info.refined_arg, info.refined_ex, info.refined_app,
         info.refined_revctx, info.refined_newprob, info.refined_newty
       in
       let subst, lhs' = subst_rec cutprob s lhs in
       let _, revctx' = subst_rec (cut_problem s (pi3 revctx)) s revctx in
       let cutnewprob = cut_problem s (pi3 newprob) in
       let subst', newprob' = subst_rec cutnewprob s newprob in
       let _, newprob_to_prob' =
         subst_rec (cut_problem s (pi3 info.refined_newprob_to_lhs)) s info.refined_newprob_to_lhs in
       let islogical = List.exists (fun (id, (recarg, f)) -> Option.has_some recarg) s in
       let ev' = if islogical then new_untyped_evar () else ev in
       let path' = Evar ev' :: path in
       let app', arg' =
         if islogical then
           let refarg = ref 0 in
           let args' =
             CList.fold_left_i
               (fun i acc c ->
                 if i == arg then (refarg := List.length acc);
                 if isRel !evd c then
                   let d = List.nth (pi1 lhs) (pred (destRel !evd c)) in
                   if List.mem_assoc (Nameops.Name.get_id (get_name d)) s then acc
                   else (mapping_constr !evd subst c) :: acc
                 else (mapping_constr !evd subst c) :: acc) 0 [] args
           in
           let secvars =
             let named_context = Environ.named_context env in
               List.map (fun decl ->
                 let id = Context.Named.Declaration.get_id decl in
                 EConstr.mkVar id) named_context
           in
           let secvars = Array.of_list secvars in
            (mkEvar (ev', secvars), List.rev args'), !refarg
         else
           let first, last = CList.chop (List.length s) (List.map (mapping_constr !evd subst) args) in
           (applistc (mapping_constr !evd subst fev) first, last), arg - List.length s
           (* FIXME , needs substituted position too *)
       in
       let info =
         { refined_obj = (id, mapping_constr !evd subst c, mapping_constr !evd subst cty);
           refined_rettyp = mapping_constr !evd subst ty;
           refined_arg = arg';
           refined_path = path';
           refined_ex = ev';
           refined_app = app';
           refined_revctx = revctx';
           refined_newprob = newprob';
           refined_newprob_to_lhs = newprob_to_prob';
           refined_newty = mapping_constr !evd subst' newty }
       in Refined (lhs', info, aux cutnewprob s p f path' sp)

    | Valid (lhs, x, y, w, u, cs) ->
       let subst, lhs' = subst_rec cutprob s lhs in
       Valid (lhs', x, y, w, u,
              List.map (fun (g, l, subst, invsubst, sp) ->
              (g, l, subst, invsubst, aux cutprob s p f path sp)) cs)
  in
  let split' = aux prob s p f path split in
  split', !where_map

let update_split env evd p is_rec f prob recs split =
  match is_rec with
  | Some (Guarded _) ->
    subst_rec_split env !evd p f [Ident p.program_id] prob recs split
  | Some (Logical r) ->
    subst_rec_split env !evd p f [] prob [] split
  | _ -> split, Evar.Map.empty


let subst_app sigma f fn c =
  let rec aux n c =
    match kind sigma c with
    | App (f', args) when eq_constr sigma f f' ->
      let args' = Array.map (map_with_binders sigma succ aux n) args in
      fn n f' args'
    | Var _ when eq_constr sigma f c ->
       fn n c [||]
    | _ -> map_with_binders sigma succ aux n c
  in aux 0 c

let substitute_alias evd ((f, fargs), term) c =
  subst_app evd f (fun n f args ->
      if n = 0 then
        let args' = filter_arguments fargs (Array.to_list args) in
        applist (term, args')
      else mkApp (f, args)) c

let substitute_aliases evd fsubst c =
  List.fold_right (substitute_alias evd) fsubst c

type alias = ((EConstr.t * int list) * Names.Id.t * Splitting.splitting)

let make_alias (f, id, s) = ((f, []), id, s)

let smash_rel_context sigma ctx =
  let open Context.Rel.Declaration in
  List.fold_right
    (fun decl (subst, pats, ctx') ->
       match get_value decl with
       | Some b ->
         let b' = substl subst b in
         (b' :: subst, List.map (lift_pat 1) pats, ctx')
       | None -> (mkRel 1 :: List.map (lift 1) subst,
                  PRel 1 :: List.map (lift_pat 1) pats,
                  map_constr (Vars.substl subst) decl :: ctx'))
    ctx ([], [], [])

let _remove_let_pats sigma subst patsubst pats =
  let remove_let pat pats =
    match pat with
    | PRel n ->
      let pat = List.nth patsubst (pred n) in
      (match pat with
       | PInac _ -> pats
       | p -> p :: pats)
    | _ -> specialize sigma patsubst pat :: pats
  in
  List.fold_right remove_let pats []

let smash_ctx_map env sigma (l, p, r as m) =
  let subst, patsubst, r' = smash_rel_context sigma r in
  let smashr' = (r, patsubst, r') in
  compose_subst env ~sigma m smashr', subst

let computations env evd alias refine eqninfo =
  let { equations_prob = prob;
        equations_where_map = wheremap;
        equations_f = f;
        equations_split = split } = eqninfo in
  let rec computations env prob f alias fsubst refine = function
  | Compute (lhs, where, ty, c) ->
     let where_comp w (wheres, where_comps) =
       (* Where term is in lhs + wheres *)
       let lhsterm = substl wheres w.where_term in
       let term, args = decompose_app evd lhsterm in
       let alias, fsubst =
         try
         let (f, id, s) = match List.hd w.where_path with
         | Evar ev -> Evar.Map.find ev wheremap
         | Ident _ -> raise Not_found in
         let f, fargs = decompose_appvect evd f in
         let args = match_arguments evd (arguments evd w.where_term) fargs in
         let fsubst = ((f, args), term) :: fsubst in
         Feedback.msg_info Pp.(str"Substituting " ++ Printer.pr_econstr_env env evd f ++
                               spc () ++
                            prlist_with_sep spc int args ++ str" by " ++
                            Printer.pr_econstr_env env evd term);
         Some ((f, args), id, s), fsubst
         with Not_found -> None, fsubst
       in
       let args' =
         let rec aux i a =
           match a with
           | [] -> []
           | hd :: tl ->
             if isRel evd hd then []
             else hd :: aux (succ i) tl
         in aux 0 args
       in
       let subterm = applist (term, args') in
       let wsmash, smashsubst = smash_ctx_map env evd w.where_prob in
       let comps = computations env wsmash subterm None fsubst (Regular,false) (Lazy.force w.where_splitting) in
       let arity = w.where_arity in
       let termf =
         if not (Evar.Map.is_empty wheremap) then
           subterm, [0]
         else
           subterm, [List.length args']
       in
       let where_comp =
         (termf, alias, w.where_orig, pi1 wsmash, substl smashsubst arity,
          List.rev_map pat_constr (pi2 wsmash) (*?*),
          [] (*?*), comps)
       in (lhsterm :: wheres, where_comp :: where_comps)
     in
     let inst, wheres = List.fold_right where_comp where ([],[]) in
     let ctx = compose_subst env ~sigma:evd lhs prob in
     if !Equations_common.debug then
       Feedback.msg_debug Pp.(str"where_instance: " ++ prlist_with_sep spc (Printer.pr_econstr_env env evd) inst);
     let fn c =
       let c' = Reductionops.nf_beta env evd (substl inst c) in
       substitute_aliases evd fsubst c'
     in
     let c' = map_rhs (fun c -> fn c) (fun x -> x) c in
     let patsconstrs = List.rev_map pat_constr (pi2 ctx) in
     let ty = substl inst ty in
     [pi1 ctx, f, alias, patsconstrs, ty,
      f, (Where, snd refine), c', Some wheres]

  | Split (_, _, _, cs) ->
    Array.fold_left (fun acc c ->
        match c with
   | None -> acc
   | Some c ->
   acc @ computations env prob f alias fsubst refine c) [] cs

  | Mapping (lhs, c) ->
     let _newprob = compose_subst env ~sigma:evd prob lhs in
     computations env prob f alias fsubst refine c

  | RecValid (id, cs) -> computations env prob f alias fsubst (fst refine, false) cs

  | Refined (lhs, info, cs) ->
     let (id, c, t) = info.refined_obj in
     let (ctx', pats', _ as s) = compose_subst env ~sigma:evd lhs prob in
     let patsconstrs = List.rev_map pat_constr pats' in
     let refinedpats = List.rev_map pat_constr
                                    (pi2 (compose_subst env ~sigma:evd info.refined_newprob_to_lhs s))
     in
     let filter = [Array.length (arguments evd (fst info.refined_app))] in
     [pi1 lhs, f, alias, patsconstrs, info.refined_rettyp, f, (Refine, true),
      RProgram (applist info.refined_app),
      Some [(fst (info.refined_app), filter), None, info.refined_path, pi1 info.refined_newprob,
            info.refined_newty, refinedpats,
            [mapping_constr evd info.refined_newprob_to_lhs c, info.refined_arg],
            computations env info.refined_newprob (fst info.refined_app) None fsubst (Regular, true) cs]]

  | Valid ((ctx,pats,del), _, _, _, _, cs) ->
     List.fold_left (fun acc (_, _, subst, invsubst, c) ->
     let subst = compose_subst env ~sigma:evd subst prob in
     acc @ computations env subst f alias fsubst (fst refine,false) c) [] cs
  in computations env prob (of_constr f) alias [] refine split

let constr_of_global_univ gr u =
  let open Globnames in
  match gr with
  | ConstRef c -> mkConstU (c, u)
  | IndRef i -> mkIndU (i, u)
  | ConstructRef c -> mkConstructU (c, u)
  | VarRef id -> mkVar id

let declare_funelim info env evd is_rec protos progs
                    ind_stmts all_stmts sign app subst inds kn comb
                    indgr ectx =
  let id = Id.of_string info.base_id in
  let leninds = List.length inds in
  let elim =
    if leninds > 1 || Lazy.force logic_sort != Sorts.InProp then comb
    else
      let elimid = Nameops.add_suffix id "_ind_ind" in
      Smartlocate.global_with_alias (Libnames.qualid_of_ident elimid)
  in
  let elimc, elimty =
    let elimty, uctx = Typeops.type_of_global_in_context (Global.env ()) elim in
    let () = evd := Evd.from_env (Global.env ()) in
    if is_polymorphic info then
      (* We merge the contexts of the term and eliminator in which
         ind_stmts and all_stmts are derived, universe unification will
         take care of unifying the eliminator's fresh instance with the
         universes of the constant and the functional induction lemma. *)
      let () = evd := Evd.merge_universe_context !evd info.term_ustate in
      let () = evd := Evd.merge_universe_context !evd ectx in
      let sigma, elimc = Evarutil.new_global !evd elim in
      let elimty = Retyping.get_type_of env sigma elimc in
      let () = evd := sigma in
      elimc, elimty
    else (* If not polymorphic, we just use the global environment's universes for f and elim *)
      (let elimc = constr_of_global_univ elim EInstance.empty in
       elimc, of_constr elimty)
  in
  let nargs, newty =
    compute_elim_type env evd info.user_obls is_rec protos kn leninds ind_stmts all_stmts
                      sign app elimty
  in
  let hookelim _ _ _ elimgr =
    let env = Global.env () in
    let evd = Evd.from_env env in
    let f_gr = Nametab.locate (Libnames.qualid_of_ident id) in
    let evd, f = new_global evd f_gr in
    let evd, elimcgr = new_global evd elimgr in
    let evd, cl = functional_elimination_class evd in
    let args_of_elim = coq_nat_of_int nargs in
    let args = [Retyping.get_type_of env evd f; f;
                Retyping.get_type_of env evd elimcgr;
                of_constr args_of_elim; elimcgr]
    in
    let instid = Nameops.add_prefix "FunctionalElimination_" id in
    let poly = is_polymorphic info in
    ignore(Equations_common.declare_instance instid poly evd [] cl args)
  in
  let tactic = ind_elim_tac elimc leninds (List.length progs) info indgr in
  let _ = e_type_of (Global.env ()) evd newty in
  ignore(Obligations.add_definition (Nameops.add_suffix id "_elim")
                                    ~tactic ~univ_hook:(Obligations.mk_univ_hook hookelim) ~kind:info.decl_kind
                                    (to_constr !evd newty) (Evd.evar_universe_context !evd) [||])

let mkConj evd x y =
  let prod = get_efresh logic_conj evd in
    mkApp (prod, [| x; y |])

let declare_funind info alias env evd is_rec protos progs
                   ind_stmts all_stmts sign inds kn comb f split ind =
  let poly = is_polymorphic info.term_info in
  let id = Id.of_string info.term_info.base_id in
  let indid = Nameops.add_suffix id "_ind_fun" in
  let args = Termops.rel_list 0 (List.length sign) in
  let f, split, unfsplit =
    match alias with
    | Some ((f, _), _, recsplit) -> f, recsplit, Some split
    | None -> f, split, None
  in
  let app = applist (f, args) in
  let statement =
    let stmt (i, ((f,_), alias, path, sign, ar, _, _, (nodek, cut)), _) =
      if not (regular_or_nested nodek) then None else
      let f, split, unfsplit =
        match alias with
        | Some ((f,_), _, recsplit) -> f, recsplit, Some split
        | None -> f, split, None
      in
      let args = extended_rel_list 0 sign in
      let app = applist (f, args) in
      let ind = Nameops.add_suffix (path_id path)(* Id.of_string info.term_info.base_id) *)
                                   ("_ind" (* ^ if i == 0 then "" else "_" ^ string_of_int i *)) in
      let indt = e_new_global evd (global_reference ind) in
      Some (it_mkProd_or_subst env !evd (applist (indt, args @ [app])) sign)
    in
    match ind_stmts with
    | [] -> assert false
    | [hd] -> Option.get (stmt hd)
    | hd :: tl ->
       let l, last =
         let rec aux l =
           let last, l = CList.sep_last l in
           match stmt last with
           | None -> aux l
           | Some t -> t, l
         in aux ind_stmts
       in
       List.fold_right (fun x acc -> match stmt x with
                                     | Some t -> mkConj evd t acc
                                     | None -> acc) last l
  in
  let hookind ectx _obls subst indgr =
    let env = Global.env () in (* refresh *)
    Hints.add_hints ~local:false [info.term_info.base_id]
                    (Hints.HintsImmediateEntry [Hints.PathAny, poly, Hints.IsGlobRef indgr]);
    let () = declare_funelim info.term_info env evd is_rec protos progs
                             ind_stmts all_stmts sign app subst inds kn comb indgr ectx in
    let evd = Evd.from_env env in
    let f_gr = Nametab.locate (Libnames.qualid_of_ident id) in
    let evd, f = new_global evd f_gr in
    let evd, indcgr = new_global evd indgr in
    let evd, cl = functional_induction_class evd in
    let args = [Retyping.get_type_of env evd f; f;
                Retyping.get_type_of env evd indcgr; indcgr]
    in
    let instid = Nameops.add_prefix "FunctionalInduction_" id in
    ignore(Equations_common.declare_instance instid poly evd [] cl args);
    (* If desired the definitions should be made transparent again. *)
    if !Equations_common.equations_transparent then
      (Global.set_strategy (ConstKey (fst (destConst evd f))) Conv_oracle.transparent;
       match alias with
       | None -> ()
       | Some ((f, _), _, _) -> Global.set_strategy (ConstKey (fst (destConst evd f))) Conv_oracle.transparent)
  in
  (* let evm, stmt = Typing.type_of (Global.env ()) !evd statement in *)
  let stmt = to_constr !evd statement and f = to_constr !evd f in
  let ctx = Evd.evar_universe_context (if poly then !evd else Evd.from_env (Global.env ())) in
  let launch_ind tactic =
    ignore(Obligations.add_definition
             ~univ_hook:(Obligations.mk_univ_hook hookind)
             ~kind:info.term_info.decl_kind
             indid stmt ~tactic:(Tacticals.New.tclTRY tactic) ctx [||])
  in
  let tac = (ind_fun_tac is_rec f info id split unfsplit progs) in
  try launch_ind tac
  with e ->
    Feedback.msg_warning Pp.(str "Induction principle could not be proved automatically: " ++ fnl () ++
                             CErrors.print e);
    launch_ind (Proofview.tclUNIT ())


let level_of_context env evd ctx acc =
  let _, lev =
    List.fold_right (fun decl (env, lev) ->
        let s = Retyping.get_sort_of env evd (get_type decl) in
        (push_rel decl env, Univ.sup (Sorts.univ_of_sort s) lev))
                    ctx (env,acc)
  in lev

let all_computations env evd alias progs =
  let comps =
    let fn p = computations env evd alias (kind_of_prog p,false) in
    List.map (fun (p, prog, eqninfo) -> p, eqninfo, fn p eqninfo) progs
  in
  let rec flatten_comp (ctx, fl, flalias, pats, ty, f, refine, c, rest) =
    let rest = match rest with
      | None -> []
      | Some l ->
         CList.map_append (fun (f, alias, path, ctx, ty, pats, newargs, rest) ->
          let nextlevel, rest = flatten_comps rest in
            ((f, alias, path, ctx, ty, pats, newargs, refine), nextlevel) :: rest) l
    in (ctx, fl, flalias, pats, ty, f, refine, c), rest
  and flatten_comps r =
    List.fold_right (fun cmp (acc, rest) ->
      let stmt, rest' = flatten_comp cmp in
        (stmt :: acc, rest' @ rest)) r ([], [])
  in
  let flatten_top_comps (p, eqninfo, one_comps) acc =
    let (top, rest) = flatten_comps one_comps in
    let topcomp = (((of_constr eqninfo.equations_f,[]), alias, [Ident p.program_id],
                    p.program_sign, p.program_arity,
                    List.rev_map pat_constr (pi2 eqninfo.equations_prob), [],
                    (kind_of_prog p,false)), top) in
    topcomp :: (rest @ acc)
  in
  List.fold_right flatten_top_comps comps []

let build_equations with_ind env evd ?(alias:alias option) rec_info progs =
  let p, prog, eqninfo = List.hd progs in
  let user_obls =
    List.fold_left (fun acc (p, prog, eqninfo) ->
      Id.Set.union prog.program_split_info.user_obls acc) Id.Set.empty progs
  in
  let { equations_id = id;
        equations_where_map = wheremap;
        equations_f = f;
        equations_prob = prob;
        equations_split = split } = eqninfo in
  let info = prog.program_split_info in
  let sign = p.program_sign in
  let cst = prog.program_cst in
  let comps = all_computations env evd alias progs in
  let protos = List.map fst comps in
  let lenprotos = List.length protos in
  let protos =
    CList.map_i (fun i ((f',filterf'), alias, path, sign, arity, pats, args, (refine, cut)) ->
      let f' = Termops.strip_outer_cast evd f' in
      let alias =
        match alias with
        | None -> None
        | Some (f, _, _) -> Some f
      in
      ((f',filterf'), alias, lenprotos - i, sign, to_constr evd arity))
      1 protos
  in
  let evd = ref evd in
  let poly = is_polymorphic info in
  let statement i filter (ctx, fl, flalias, pats, ty, f', (refine, cut), c) =
    let hd, unf = match flalias with
      | Some ((f', _), unf, _) ->
        let tac = Proofview.tclBIND
            (Tacticals.New.pf_constr_of_global (Nametab.locate (Libnames.qualid_of_ident unf)))
            Equality.rewriteLR in
        f', tac

      | None -> fl,
        if eq_constr !evd fl (of_constr f) then
          Tacticals.New.tclORELSE Tactics.reflexivity (of82 (unfold_constr !evd (of_constr f)))
        else Tacticals.New.tclIDTAC
    in
    let comp = applistc hd pats in
    let body =
      let b = match c with
        | RProgram c ->
            mkEq env evd ty comp (Reductionops.nf_beta env !evd c)
        | REmpty i ->
           mkApp (coq_ImpossibleCall evd, [| ty; comp |])
      in
      let body = it_mkProd_or_LetIn b ctx in
      if !Equations_common.debug then
        Feedback.msg_debug Pp.(str"Typing equation " ++ Printer.pr_econstr_env env !evd body);
      let _ = Equations_common.evd_comb1 (Typing.type_of env) evd body in
      body
    in
    let cstr =
      match c with
      | RProgram c ->
          let len = List.length ctx in
          let hyps, hypslen, c' =
            abstract_rec_calls !evd user_obls rec_info len protos (Reductionops.nf_beta env !evd c)
          in
          let head =
            let f = mkRel (len + (lenprotos - i) + hypslen) in
            if cut then f
            else
              let fn, args = decompose_app !evd (Termops.strip_outer_cast !evd fl) in
              applistc f (filter_arguments filter (lift_constrs hypslen args))
          in
          let ty =
            it_mkProd_or_clear !evd
              (it_mkProd_or_clean env !evd
                 (applistc head (lift_constrs hypslen pats @ [c']))
                 hyps) ctx
          in Some ty
      | REmpty i -> None
    in (refine, unf, body, cstr)
  in
  let statements i ((f', alias, path, sign, arity, pats, args, refine as fs), c) =
    let fs, filter =
      match alias with
      | Some (f', unf, split) ->
         (f', None, path, sign, arity, pats, args, refine), snd f'
      | None -> fs, snd f'
    in fs, List.map (statement i filter) c in
  let stmts = CList.map_i statements 0 comps in
  let ind_stmts = CList.map_i
    (fun i (f, c) -> i, f, CList.map_i (fun j x -> j, x) 1 c) 0 stmts
  in
  let all_stmts = List.concat (List.map (fun (f, c) -> c) stmts) in
  let fnind_map = ref PathMap.empty in
  let declare_one_ind (i, (f, alias, path, sign, arity, pats, refs, refine), stmts) =
    let indid = Nameops.add_suffix (path_id path) "_ind" (* (if i == 0 then "_ind" else ("_ind_" ^ string_of_int i)) *) in
    let indapp = List.rev_map (fun x -> Constr.mkVar (Nameops.Name.get_id (get_name x))) sign in
    let () = fnind_map := PathMap.add path (indid,indapp) !fnind_map in
    let constructors = CList.map_filter (fun (_, (_, _, _, n)) -> Option.map (to_constr !evd) n) stmts in
    let consnames = CList.map_filter (fun (i, (r, _, _, n)) ->
      Option.map (fun _ ->
        let suff = (if r != Refine then "_equation_" else "_refinement_") ^ string_of_int i in
          Nameops.add_suffix indid suff) n) stmts
    in
    let ind_sort =
      if Lazy.force logic_sort == Sorts.InProp then
        (* Define graph impredicatively *)
        mkProp
      else (* Compute sort as max of products *)
        let ctx = (of_tuple (Anonymous, None, arity) :: sign) in
        let signlev = level_of_context env !evd ctx Univ.type0m_univ in
        mkSort (Sorts.sort_of_univ signlev)
    in
    (* let fullsign, arity = Reductionops.splay_prod_assum (push_rel_context sign env) !evd arity in *)
      Entries.{ mind_entry_typename = indid;
        mind_entry_arity = to_constr !evd (it_mkProd_or_LetIn (mkProd (Anonymous, arity, ind_sort)) (sign));
        mind_entry_consnames = consnames;
        mind_entry_lc = constructors;
        mind_entry_template = false }
  in
  let declare_ind () =
    let inds = List.map declare_one_ind ind_stmts in
    let uctx = Evd.ind_univ_entry ~poly !evd in
    let inductive =
      Entries.{ mind_entry_record = None;
                mind_entry_universes = uctx;
                mind_entry_private = None;
                mind_entry_finite = Declarations.Finite;
                mind_entry_params = []; (* (identifier * local_entry) list; *)
                mind_entry_inds = inds }
    in
    let () = Goptions.set_bool_option_value_gen ~locality:Goptions.OptLocal ["Elimination";"Schemes"] false in
    let kn = ComInductive.declare_mutual_inductive_with_eliminations inductive UnivNames.empty_binders [] in
    let () = Goptions.set_bool_option_value_gen ~locality:Goptions.OptLocal ["Elimination";"Schemes"] true in
    let kn, comb =
      let sort = Lazy.force logic_sort in
      let suff = match sort with
        | Sorts.InProp -> "_ind"
        | Sorts.InSet ->  "_rec"
        | Sorts.InType -> "_rect"
      in
      let mutual =
        (CList.map_i (fun i ind ->
             let suff = if List.length inds != 1 then "_mut" else suff in
             let id = CAst.make @@ Nameops.add_suffix ind.Entries.mind_entry_typename suff in
             (id, false, (kn, i), sort)) 0 inds)
      in
      Indschemes.do_mutual_induction_scheme mutual;
      if List.length inds != 1 then
        let scheme = Nameops.add_suffix (Id.of_string info.base_id) "_ind_comb" in
        let mutual = List.map2 (fun (i, _, _, _) (_, (_, _, _, _, _, _, _, (kind, cut)), _) ->
                         i, regular_or_nested_rec kind) mutual ind_stmts in
        let () =
          Indschemes.do_combined_scheme CAst.(make scheme)
            (CList.map_filter (fun (id, b) -> if b then Some id else None) mutual)
        in kn, Smartlocate.global_with_alias (Libnames.qualid_of_ident scheme)
      else
        let scheme = Nameops.add_suffix (Id.of_string info.base_id) ("_ind" ^ suff) in
        kn, Smartlocate.global_with_alias (Libnames.qualid_of_ident scheme)
    in
    let ind =
      let open Entries in
      match uctx with
      | Cumulative_ind_entry (_, uctx) ->
        mkIndU ((kn,0), EInstance.make (Univ.UContext.instance
                                          (Univ.CumulativityInfo.univ_context uctx)))
      | Polymorphic_ind_entry (_, uctx) ->
        mkIndU ((kn,0), EInstance.make (Univ.UContext.instance uctx))
      | Monomorphic_ind_entry _ -> mkInd (kn,0)
    in
    let _ =
      List.iteri (fun i ind ->
        let constrs =
          CList.map_i (fun j _ -> Hints.empty_hint_info, poly, true, Hints.PathAny,
            Hints.IsGlobRef (Globnames.ConstructRef ((kn,i),j))) 1 ind.Entries.mind_entry_lc in
          Hints.add_hints ~local:false [info.base_id] (Hints.HintsResolveEntry constrs))
        inds
    in
    let info = { term_info = info; pathmap = !fnind_map; wheremap } in
    declare_funind info alias (Global.env ()) evd rec_info protos progs
                   ind_stmts all_stmts sign inds kn comb
                   (of_constr f) split ind
  in
  let () = evd := Evd.minimize_universes !evd in
  let () =
    if not poly then
      (* Declare the universe context necessary to typecheck the following
          definitions once and for all. *)
      (Declare.declare_universe_context false (Evd.universe_context_set !evd);
       evd := Evd.from_env (Global.env ()))
    else ()
  in
  let proof (j, (_, alias, path, sign, arity, pats, refs, refine), stmts) =
    let eqns = Array.make (List.length stmts) false in
    let id = path_id path in (* if j != 0 then Nameops.add_suffix id ("_helper_" ^ string_of_int j) else id in *)
    let proof (i, (r, unf, c, n)) =
      let ideq = Nameops.add_suffix id ("_equation_" ^ string_of_int i) in
      let hook _ _obls subst gr =
        if n != None then
          Autorewrite.add_rew_rules info.base_id
            [CAst.make (UnivGen.fresh_global_instance (Global.env()) gr, true, None)]
        else (Typeclasses.declare_instance None true gr
              (* Hints.add_hints ~local:false [info.base_id]  *)
              (*                 (Hints.HintsExternEntry *)
              (*                  (Vernacexpr.{hint_priority = Some 0; hint_pattern = None}, *)
              (*                   impossible_call_tac (Globnames.ConstRef cst))) *));
        eqns.(pred i) <- true;
        if CArray.for_all (fun x -> x) eqns then (
          (* From now on, we don't need the reduction behavior of the constant anymore *)
          Typeclasses.set_typeclass_transparency (EvalConstRef cst) false false;
          (match alias with
           | Some ((f, _), _, _) ->
              Global.set_strategy (ConstKey (fst (destConst !evd f))) Conv_oracle.Opaque
           | None -> ());
          Global.set_strategy (ConstKey cst) Conv_oracle.Opaque;
          if with_ind && succ j == List.length ind_stmts then declare_ind ())
      in
      let tac =
        let open Tacticals.New in
        tclTHENLIST
          [Tactics.intros;
           unf;
           (solve_equation_tac (Globnames.ConstRef cst));
           (if Evar.Map.is_empty wheremap then Tacticals.New.tclIDTAC
            else tclTRY (of82 (autorewrites (info.base_id ^ "_where"))));
           Tactics.reflexivity]
      in
      let () =
        (* Refresh at each equation, accumulating known constraints. *)
        if not poly then evd := Evd.from_env (Global.env ())
        else ()
      in
      ignore(Obligations.add_definition
               ~kind:info.decl_kind
               ideq (to_constr !evd c)
               ~tactic:tac ~univ_hook:(Obligations.mk_univ_hook hook)
	       (Evd.evar_universe_context !evd) [||])
    in List.iter proof stmts
  in List.iter proof ind_stmts
