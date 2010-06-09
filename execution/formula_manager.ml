(*
 Owned and copyright BitBlaze, 2009-2010. All rights reserved.
 Do not copy, disclose, or distribute without explicit written
 permission.
*)

module V = Vine;;

open Exec_domain;;
open Exec_exceptions;;
open Exec_options;;
open Frag_simplify;;

module FormulaManagerFunctor =
  functor (D : Exec_domain.DOMAIN) ->
struct
  (* This has to be outside the class because I want it to have
     polymorphic type. *)
  let if_expr_temp form_man var fn_t else_val else_fn =
    let box = ref else_val in
      form_man#if_expr_temp_unit var
	(fun e -> 
	   match e with
	     | Some (e) -> box := fn_t e
	     | None -> (else_fn var)
	);
      !box

  class formula_manager = object(self)
    val input_vars = Hashtbl.create 30

    method private fresh_symbolic_var str ty =
      try Hashtbl.find input_vars str with
	  Not_found ->
	    Hashtbl.replace input_vars str (V.newvar str ty);
	    Hashtbl.find input_vars str

    method private fresh_symbolic_vexp str ty =
      V.Lval(V.Temp(self#fresh_symbolic_var str ty))

    method private fresh_symbolic str ty =
      let v = D.from_symbolic (self#fresh_symbolic_vexp str ty) in
	if !opt_use_tags then
	  Printf.printf "Symbolic %s is %Ld\n" str (D.get_tag v);
	v

    method input_dl =
      Hashtbl.fold (fun k v l -> v :: l) input_vars []

    method fresh_symbolic_1  s = self#fresh_symbolic s V.REG_1
    method fresh_symbolic_8  s = self#fresh_symbolic s V.REG_8
    method fresh_symbolic_16 s = self#fresh_symbolic s V.REG_16
    method fresh_symbolic_32 s = self#fresh_symbolic s V.REG_32
    method fresh_symbolic_64 s = self#fresh_symbolic s V.REG_64

    method get_input_vars = Hashtbl.fold (fun s v l -> v :: l) input_vars []

    val region_base_vars = Hashtbl.create 30

    method fresh_region_base s =
      assert(not (Hashtbl.mem region_base_vars s));
      let var = self#fresh_symbolic_var s V.REG_32 in
	Hashtbl.replace region_base_vars s var;
	D.from_symbolic (V.Lval(V.Temp(var)))

    method known_region_base ((_,s,_):V.var) =
      Hashtbl.mem region_base_vars s

    val region_vars = Hashtbl.create 30

    method private fresh_symbolic_mem ty str addr =
      let v = try Hashtbl.find region_vars str with
	  Not_found ->
	    Hashtbl.replace region_vars str
	      (V.newvar str (V.TMem(V.REG_32, V.Little)));
	    Hashtbl.find region_vars str
      in
	D.from_symbolic
	  (V.Lval(V.Mem(v, V.Constant(V.Int(V.REG_32, addr)), ty)))

    method fresh_symbolic_mem_1  = self#fresh_symbolic_mem V.REG_1
    method fresh_symbolic_mem_8  = self#fresh_symbolic_mem V.REG_8
    method fresh_symbolic_mem_16 = self#fresh_symbolic_mem V.REG_16
    method fresh_symbolic_mem_32 = self#fresh_symbolic_mem V.REG_32
    method fresh_symbolic_mem_64 = self#fresh_symbolic_mem V.REG_64

    val seen_concolic = Hashtbl.create 30
    val valuation = Hashtbl.create 30

    method private make_concolic ty str v =
      let var =
	(if Hashtbl.mem seen_concolic (str, 0L, ty) then
	   let var = Hashtbl.find seen_concolic (str, 0L, ty) in
	   let old_val = Hashtbl.find valuation var in
	     if v <> old_val then
	       if !opt_trace_unexpected then
		 Printf.printf
		   "Value mismatch: %s was 0x%Lx and then later 0x%Lx\n"
		   str old_val v;
	     var
	 else 
	   (let new_var = self#fresh_symbolic str ty in
	      Hashtbl.replace seen_concolic (str, 0L, ty) new_var;
	      new_var))
      in
	if !opt_trace_taint then
	  Printf.printf "Valuation %s = 0x%Lx:%s\n"
	    str v (V.type_to_string ty);
	Hashtbl.replace valuation var v;
	var

    method make_concolic_8  s v = self#make_concolic V.REG_8  s(Int64.of_int v)
    method make_concolic_16 s v = self#make_concolic V.REG_16 s(Int64.of_int v)
    method make_concolic_32 s v = self#make_concolic V.REG_32 s v
    method make_concolic_64 s v = self#make_concolic V.REG_64 s v

    method make_concolic_mem_8 str addr v_int =
      let v = Int64.of_int v_int in
      let var =
	(if Hashtbl.mem seen_concolic (str, addr, V.REG_8) then
	   let var = Hashtbl.find seen_concolic (str, addr, V.REG_8) in
	   let old_val = Hashtbl.find valuation var in
	     if v <> old_val then
	       if !opt_trace_unexpected then
		 Printf.printf
		   "Value mismatch: %s:0x%Lx was 0x%Lx and then later 0x%Lx\n"
		   str addr old_val v;
	     var
	 else 
	   (let new_var = self#fresh_symbolic_mem V.REG_8 str addr in
	      Hashtbl.replace seen_concolic (str, addr, V.REG_8) new_var;
	      new_var))
      in
	if !opt_trace_taint then
	  Printf.printf "Byte valuation %s:0x%Lx = 0x%Lx\n"
	    str addr v;
	Hashtbl.replace valuation var v;
	(match !input_string_mem_prefix with
	   | None -> input_string_mem_prefix := Some (str ^ "_byte_")
	   | _ -> ());
	max_input_string_length :=
	  max !max_input_string_length (1 + Int64.to_int addr);
	var

    method private mem_var region_str ty addr =
      let ty_str = (match ty with
		      | V.REG_8 -> "byte"
		      | V.REG_16 -> "short"
		      | V.REG_32 -> "word"
		      | V.REG_64 -> "long"
		      | _ -> failwith "Bad size in mem_var")
      in
      let name = Printf.sprintf "%s_%s_0x%08Lx" region_str ty_str addr
      in
	self#fresh_symbolic_var name ty

    val mem_byte_vars = V.VarHash.create 30

    method private mem_var_byte region_str addr =
      let var = self#mem_var region_str V.REG_8 addr in
	V.VarHash.replace mem_byte_vars var ();
	var

    method private mem_axioms_short region_str addr svar =
      let bvar0 = self#mem_var_byte region_str addr and
	  bvar1 = self#mem_var_byte region_str (Int64.add addr 1L) in
	[svar, D.to_symbolic_16
	   (D.assemble16 (D.from_symbolic (V.Lval(V.Temp(bvar0))))
	      (D.from_symbolic (V.Lval(V.Temp(bvar1)))))]

    method private mem_axioms_word region_str addr wvar =
      let svar0 = self#mem_var region_str V.REG_16 addr and
	  svar1 = self#mem_var region_str V.REG_16 (Int64.add addr 2L) in
	[wvar, D.to_symbolic_32
	   (D.assemble32 (D.from_symbolic (V.Lval(V.Temp(svar0))))
	      (D.from_symbolic (V.Lval(V.Temp(svar1)))))]
	@ (self#mem_axioms_short region_str addr svar0)
	@ (self#mem_axioms_short region_str (Int64.add addr 2L) svar1)

    method private mem_axioms_long region_str addr lvar =
      let wvar0 = self#mem_var region_str V.REG_32 addr and
	  wvar1 = self#mem_var region_str V.REG_32 (Int64.add addr 4L) in
	[lvar, D.to_symbolic_64
	   (D.assemble32 (D.from_symbolic (V.Lval(V.Temp(wvar0))))
	      (D.from_symbolic (V.Lval(V.Temp(wvar1)))))]
	@ (self#mem_axioms_word region_str addr wvar0)
	@ (self#mem_axioms_word region_str (Int64.add addr 4L) wvar1)

    val mem_axioms = V.VarHash.create 30

    method private add_mem_axioms region_str ty addr =
      let var = self#mem_var region_str ty addr in
	if ty = V.REG_8 then
	  V.VarHash.replace mem_byte_vars var ()
	else
	  let al = (match ty with
		      | V.REG_8  -> failwith "Unexpected REG_8"
		      | V.REG_16 -> self#mem_axioms_short region_str addr var
		      | V.REG_32 -> self#mem_axioms_word region_str addr var
		      | V.REG_64 -> self#mem_axioms_long region_str addr var
		      | _ -> failwith "Unexpected type in add_mem_axioms") in
	    List.iter
	      (fun (lhs, rhs) -> V.VarHash.replace mem_axioms lhs rhs)
	      al;
	    assert(V.VarHash.mem mem_axioms var);

    method private rewrite_mem_expr e =
      match e with
	| V.Lval(V.Mem((_,region_str,ty1),
		       V.Constant(V.Int(V.REG_32, addr)), ty2))
	  -> (self#add_mem_axioms region_str ty2 addr;
	      V.Lval(V.Temp(self#mem_var region_str ty2 addr)))
	| _ -> failwith "Bad expression in rewrite_mem_expr"

    method rewrite_for_solver e =
      let rec loop e =
	match e with
	  | V.BinOp(op, e1, e2) -> V.BinOp(op, (loop e1), (loop e2))
	  | V.UnOp(op, e1) -> V.UnOp(op, (loop e1))
	  | V.Constant(_) -> e
	  | V.Lval(V.Temp(_)) -> e
	  | V.Lval(V.Mem(_, _, _)) -> self#rewrite_mem_expr e
	  | V.Name(_) -> e
	  | V.Cast(kind, ty, e1) -> V.Cast(kind, ty, (loop e1))
	  | V.Unknown(_) -> e
	  | V.Let(V.Temp(v), e1, e2) ->
	      V.Let(V.Temp(v), (loop e1), (loop e2))
	  | V.Let(V.Mem(_,_,_), _, _) ->	      
	      failwith "Unexpected memory let in rewrite_for_solver"
      in
	loop e

    method get_mem_axioms =
      let of_type ty ((n,s,ty'),e) = (ty = ty') in
      let l = V.VarHash.fold
	(fun lhs rhs l -> (lhs, rhs) :: l) mem_axioms [] in
      let shorts = List.filter (of_type V.REG_16) l and
	  words  = List.filter (of_type V.REG_32) l and
	  longs  = List.filter (of_type V.REG_64) l in
	shorts @ words @ longs

    method get_mem_bytes =
      V.VarHash.fold (fun v _ l -> v :: l) mem_byte_vars []

    method reset_mem_axioms = 
      V.VarHash.clear mem_byte_vars;
      V.VarHash.clear mem_axioms

    method private eval_mem_var lv =
      let d = D.from_symbolic (V.Lval lv) in
	match lv with
	  | V.Mem(mem_var, V.Constant(V.Int(_, addr)), V.REG_8) ->
	      assert(Hashtbl.mem valuation d);
	      D.from_concrete_8 (Int64.to_int (Hashtbl.find valuation d))
	  | V.Mem(mem_var, V.Constant(V.Int(_, addr)), V.REG_16) ->
	      if Hashtbl.mem valuation d then
		D.from_concrete_16 (Int64.to_int (Hashtbl.find valuation d))
	      else
		D.assemble16
		  (self#eval_mem_var
		     (V.Mem(mem_var, V.Constant(V.Int(V.REG_32, addr)),
			    V.REG_8)))
		  (self#eval_mem_var
		     (V.Mem(mem_var,
			    V.Constant(V.Int(V.REG_32, 
					     (Int64.add 1L addr))),
			    V.REG_8)))
	  | V.Mem(mem_var, V.Constant(V.Int(_, addr)), V.REG_32) ->
	      if Hashtbl.mem valuation d then
		D.from_concrete_32 (Hashtbl.find valuation d)
	      else
		D.assemble32
		  (self#eval_mem_var
		     (V.Mem(mem_var, V.Constant(V.Int(V.REG_32, addr)),
			    V.REG_16)))
		  (self#eval_mem_var
		     (V.Mem(mem_var, V.Constant(V.Int(V.REG_32, 
						      (Int64.add 2L addr))),
			    V.REG_16)))
	  | V.Mem(mem_var, V.Constant(V.Int(_, addr)), V.REG_64) ->
	      if Hashtbl.mem valuation d then
		D.from_concrete_64 (Hashtbl.find valuation d)
	      else
		D.assemble64
		  (self#eval_mem_var
		     (V.Mem(mem_var, V.Constant(V.Int(V.REG_32, addr)),
			    V.REG_32)))
		  (self#eval_mem_var
		     (V.Mem(mem_var, V.Constant(V.Int(V.REG_32, 
						      (Int64.add 4L addr))),
			    V.REG_32)))
	  | _ -> failwith "unexpected lval expr in eval_mem_var"

    (* subexpression cache *)
    val subexpr_to_temp_var = Hashtbl.create 1001
    val temp_var_to_subexpr = V.VarHash.create 1001
    val mutable temp_var_num = 0

    val temp_var_evaled = V.VarHash.create 1001

    method eval_expr e =
      let cf_eval e =
	match Vine_opt.constant_fold (fun _ -> None) e with
	  | V.Constant(V.Int(_, _)) as c -> c
	  | e ->
	      Printf.printf "Left with %s\n" (V.exp_to_string e);
	      failwith "cf_eval failed in eval_expr"
      in
      let rec loop e =
	match e with
	  | V.BinOp(op, e1, e2) -> cf_eval (V.BinOp(op, loop e1, loop e2))
	  | V.UnOp(op, e1) -> cf_eval (V.UnOp(op, loop e1))
	  | V.Cast(op, ty, e1) -> cf_eval (V.Cast(op, ty, loop e1))
	  | V.Lval(V.Mem(_, _, ty) as lv) ->
	      let d = self#eval_mem_var lv in
	      let v = match ty with
		| V.REG_8  -> Int64.of_int (D.to_concrete_8  d)
		| V.REG_16 -> Int64.of_int (D.to_concrete_16 d)
		| V.REG_32 -> D.to_concrete_32 d
		| V.REG_64 -> D.to_concrete_64 d
		| _ -> failwith "Unexpected type in eval_expr"
	      in
		V.Constant(V.Int(ty, v))
	  | V.Constant(V.Int(_, _)) -> e
	  | V.Lval(V.Temp(var))
	      when V.VarHash.mem temp_var_to_subexpr var ->
	      (try V.VarHash.find temp_var_evaled var
	       with
		 | Not_found ->
		     let e' = loop (V.VarHash.find temp_var_to_subexpr var)
		     in
		       V.VarHash.replace temp_var_evaled var e';
		       e')
	  | _ ->
	      Printf.printf "Can't evaluate %s\n" (V.exp_to_string e);
	      failwith "Unexpected expr in eval_expr"
      in
	match loop e with
	  | V.Constant(V.Int(_, i64)) -> i64
	  | e ->
	      Printf.printf "Left with %s\n" (V.exp_to_string e);
	      failwith "Constant invariant failed in eval_expr"


    method private simplify (v:D.t) ty =
      D.inside_symbolic
	(fun e ->
	   let e' = simplify_rec e in
	     if expr_size e' < 10 then
	       e'
	     else
	       let e'_str = V.exp_to_string e' in
	       let var =
		 (try
		    Hashtbl.find subexpr_to_temp_var e'_str
		  with Not_found ->
		    let s = "t" ^ (string_of_int temp_var_num) in
		      temp_var_num <- temp_var_num + 1;
		      let var = V.newvar s ty in
 			Hashtbl.replace subexpr_to_temp_var e'_str var;
 			V.VarHash.replace temp_var_to_subexpr var e';
			if !opt_trace_temps then
			  Printf.printf "%s = %s\n" s (V.exp_to_string e');
			var) in
		 V.Lval(V.Temp(var))) v
	      
    method simplify1  e = self#simplify e V.REG_1
    method simplify8  e = self#simplify e V.REG_8
    method simplify16 e = self#simplify e V.REG_16
    method simplify32 e = self#simplify e V.REG_32
    method simplify64 e = self#simplify e V.REG_64

    method if_expr_temp_unit var (fn_t: V.exp option  -> unit) =
      try
	let e = V.VarHash.find temp_var_to_subexpr var in
	  (fn_t (Some(e)) )
      with Not_found -> (fn_t None)
	
    (* This was originally designed to be polymorphic in the return
       type of f, and could be made so again as with if_expr_temp *)
    method walk_temps (f : (V.var -> V.exp -> (V.var * V.exp))) exp =
      let h = V.VarHash.create 21 in
      let temps = ref [] in
      let nontemps_h = V.VarHash.create 21 in
      let nontemps = ref [] in
      let rec walk = function
	| V.BinOp(_, e1, e2) -> walk e1; walk e2
	| V.UnOp(_, e1) -> walk e1
	| V.Constant(_) -> ()
	| V.Lval(V.Temp(var)) ->
	    if not (V.VarHash.mem h var) then
	      (let fn_t = (fun e ->
			     V.VarHash.replace h var ();
			     walk e;
			     temps := (f var e) :: !temps) in
	       let else_fn =
		 (fun v -> (* v is not a temp *)
		    if not (V.VarHash.mem nontemps_h var) then
		      (V.VarHash.replace nontemps_h var ();
		       nontemps := var :: !nontemps)) in
		 if_expr_temp self var fn_t () else_fn)	   
	| V.Lval(V.Mem(_, e1, _)) -> walk e1
	| V.Name(_) -> ()
	| V.Cast(_, _, e1) -> walk e1
	| V.Unknown(_) -> ()
	| V.Let(_, e1, e2) -> walk e1; walk e2 
      in
	walk exp;
	((List.rev !nontemps), (List.rev !temps))

    method conjoin l =
      match l with
	| [] -> V.exp_true
	| e :: el -> List.fold_left (fun a b -> V.BinOp(V.BITAND, a, b)) e el

    method disjoin l =
      match l with
	| [] -> V.exp_false
	| e :: el -> List.fold_left (fun a b -> V.BinOp(V.BITOR, a, b)) e el

    method collect_for_solving u_temps conds val_e =
      (* Unlike Vine_util.list_unique, this preserves order (keeping the
	 first occurrence) which is important because the temps have to
	 retain a topological ordering. *)
      let list_unique l = 
	let h = Hashtbl.create 10 in
	let rec loop = function
	  | [] -> []
	  | e :: el ->
	      if Hashtbl.mem h e then
		loop el
	      else
		(Hashtbl.replace h e ();
		 e :: (loop el))
	in
	  (loop l)
      in
      let val_expr = self#rewrite_for_solver val_e in
      let cond_expr = self#rewrite_for_solver
	(self#conjoin (List.rev conds)) in
      let (nts1, ts1) = self#walk_temps (fun var e -> (var, e)) cond_expr in
      let (nts2, ts2) = self#walk_temps (fun var e -> (var, e)) val_expr in
      let (nts3, ts3) = List.fold_left 
	(fun (ntl, tl) (lhs, rhs) ->
	   let (nt, t) = self#walk_temps (fun var e -> (var, e)) rhs in
	     (nt @ ntl, t @ tl))
	([], []) u_temps in
      let temps = 
	List.map (fun (var, e) -> (var, self#rewrite_for_solver e))
	  (list_unique (ts1 @ ts2 @ ts3 @ u_temps)) in
      let i_vars =
	list_unique (nts1 @ nts2 @ nts3 @ self#get_mem_bytes) in
      let m_axioms = self#get_mem_axioms in
      let m_vars = List.map (fun (v, _) -> v) m_axioms in
      let assigns = m_axioms @ temps in
      let decls = Vine_util.list_difference i_vars m_vars in
      let inputs_in_val_expr = i_vars 
      in
	(decls, assigns, cond_expr, val_expr, inputs_in_val_expr)

    method measure_size =
      let (input_ents, input_nodes) =
	(Hashtbl.length input_vars, Hashtbl.length input_vars) in
      let (rb_ents, rb_nodes) =
	(Hashtbl.length region_base_vars, Hashtbl.length region_base_vars) in
      let (rg_ents, rg_nodes) =
	(Hashtbl.length region_vars, Hashtbl.length region_vars) in
      let sc_ents = Hashtbl.length seen_concolic in
      let (bv_ents, bv_nodes) =
	(Hashtbl.length valuation, Hashtbl.length valuation) in
      let (se2t_ents, se2t_nodes) = 
	(Hashtbl.length subexpr_to_temp_var,
	 Hashtbl.length subexpr_to_temp_var) in
      let mbv_ents = V.VarHash.length mem_byte_vars in
      let sum_expr_sizes k v sum = sum + expr_size v in
      let (ma_ents, ma_nodes) =
	(V.VarHash.length mem_axioms,
	 V.VarHash.fold sum_expr_sizes mem_axioms 0) in
      let (t2se_ents, t2se_nodes) =
	(V.VarHash.length temp_var_to_subexpr,
	 V.VarHash.fold sum_expr_sizes temp_var_to_subexpr 0) in
      let te_ents = V.VarHash.length temp_var_evaled in
	Printf.printf "input_vars has %d entries\n" input_ents;
	Printf.printf "region_base_vars has %d entries\n" rb_ents;
	Printf.printf "region_vars has %d entries\n" rg_ents;
	Printf.printf "seen_concolic has %d entries\n" sc_ents;
	Printf.printf "valuation has %d entries\n" bv_ents;
	Printf.printf "subexpr_to_temp_var has %d entries\n" se2t_ents;
	Printf.printf "mem_byte_vars has %d entries\n" mbv_ents;
	Printf.printf "mem_axioms has %d entries and %d nodes\n"
	  ma_ents ma_nodes;
	Printf.printf "temp_var_to_subexpr has %d entries and %d nodes\n"
	  t2se_ents t2se_nodes;
	(input_ents + rb_ents + rg_ents + sc_ents + bv_ents + se2t_ents +
	   mbv_ents + ma_ents + t2se_ents + te_ents,
	 input_nodes + rb_nodes + rg_nodes + bv_nodes + se2t_nodes +
	   ma_nodes + t2se_nodes)
  end
end
