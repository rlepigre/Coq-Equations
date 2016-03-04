(**********************************************************************)
(* Equations                                                          *)
(* Copyright (c) 2009-2015 Matthieu Sozeau <matthieu.sozeau@inria.fr> *)
(**********************************************************************)
(* This file is distributed under the terms of the                    *)
(* GNU Lesser General Public License Version 2.1                      *)
(**********************************************************************)

Require Import Equations.Init.

(** Decidable equality.

   We redevelop the derivation of [K] from decidable equality on [A] making
   everything transparent and moving to [Type] so that programs using this 
   will actually be computable inside Coq. *)

Set Implicit Arguments.

Definition dec_eq {A} (x y : A) := 
  { x = y } + { x <> y }.

Class EqDec (A : Type) :=
  eq_dec : forall x y : A, { x = y } + { x <> y }.

(** Tactic to solve EqDec goals, destructing recursive calls for the recursive 
  structure of the type and calling instances of eq_dec on other types. *)

Ltac eqdec_loop t u :=
  (left; reflexivity) || 
  (solve [right; intro He; noconf He]) ||
  (let x := match t with
             | appcontext C [ _ ?x ] => constr:x
             end
    in
    let y := match u with
             | appcontext C [ _ ?y ] => constr:y
             end
    in
    let contrad := intro Hn; right; intro He; noconf He; apply Hn; reflexivity in
    let good := intros ->;
      let t' := match t with
                | appcontext C [ ?x _ ] => constr:x
                end
      in
      let u' := match u with
                | appcontext C [ ?y _ ] => constr:y
                end
      in
      (* idtac "there" t' u'; *)  try (eqdec_loop t' u')
    in
    (* idtac "here" x y; *)
    match goal with
      [ H : forall z, dec_eq x z |- _ ] =>
      case (H y); [good|contrad]
    | [ H : forall z, { x = z } + { _ } |- _ ] =>
      case (H y); [good|contrad]
    | _ => case (eq_dec x y); [good|contrad]
    end) || idtac.

Ltac eqdec_proof := try red; intros;
  match goal with
    |- dec_eq ?x ?y =>
    revert y; induction x; intros until y; depelim y;
    match goal with
      |- dec_eq ?x ?y => eqdec_loop x y
    end
   | |- { ?x = ?y } + { _ } =>
    revert y; induction x; intros until y; depelim y;
    match goal with
      |- { ?x = ?y } + { _ } => eqdec_loop x y
    end
  end.

(** Standard instances. *)

Instance unit_eqdec : EqDec unit. 
Proof. eqdec_proof. Defined.

Instance bool_eqdec : EqDec bool. 
Proof. eqdec_proof. Defined.

Instance nat_eqdec : EqDec nat.
Proof. eqdec_proof. Defined.

Instance prod_eqdec {A B} `(EqDec A) `(EqDec B) : EqDec (prod A B).
Proof. eqdec_proof. Defined.

Instance sum_eqdec {A B} `(EqDec A) `(EqDec B) : EqDec (A + B).
Proof. eqdec_proof. Defined.

Instance list_eqdec {A} `(EqDec A) : EqDec (list A). 
Proof. eqdec_proof. Defined.

(** Derivation of principles on sigma types whose domain is decidable. *)

Section EqdepDec.

  Context {A : Type} `{EqDec A}.

  Let comp (x y y':A) (eq1:x = y) (eq2:x = y') : y = y' :=
    eq_ind _ (fun a => a = y') eq2 _ eq1.

  Remark trans_sym_eq : forall (x y:A) (u:x = y), comp u u = refl_equal y.
  Proof.
    intros.
    case u; trivial.
  Defined.

  Variable x : A.

  Let nu (y:A) (u:x = y) : x = y :=
    match eq_dec x y with
      | left eqxy => eqxy
      | right neqxy => False_ind _ (neqxy u)
    end.

  Let nu_constant : forall (y:A) (u v:x = y), nu u = nu v.
    intros.
    unfold nu in |- *.
    case (eq_dec x y); intros.
    reflexivity.

    case n; trivial.
  Defined.

  Let nu_inv (y:A) (v:x = y) : x = y := comp (nu (refl_equal x)) v.

  Remark nu_left_inv : forall (y:A) (u:x = y), nu_inv (nu u) = u.
  Proof.
    intros.
    case u; unfold nu_inv in |- *.
    apply trans_sym_eq.
  Defined.

  Theorem eq_proofs_unicity : forall (y:A) (p1 p2:x = y), p1 = p2.
  Proof.
    intros.
    elim nu_left_inv with (u := p1).
    elim nu_left_inv with (u := p2).
    elim nu_constant with y p1 p2.
    reflexivity.
  Defined.

  Theorem K_dec :
    forall P:x = x -> Type, P (refl_equal x) -> forall p:x = x, P p.
  Proof.
    intros.
    elim eq_proofs_unicity with x (refl_equal x) p.
    trivial.
  Defined.

  Lemma eq_dec_refl : eq_dec x x = left _ (eq_refl x).
  Proof. case eq_dec. intros. f_equal. apply eq_proofs_unicity. 
    intro. congruence.
  Defined.

  (** The corollary *)

  Let proj (P:A -> Type) (exP:sigT P) (def:P x) : P x :=
    match exP with
      | existT _ x' prf =>
        match eq_dec x' x with
          | left eqprf => eq_rect x' P prf x eqprf
          | _ => def
        end
    end.

  Theorem inj_right_pair :
    forall (P:A -> Type) (y y':P x),
      existT P x y = existT P x y' -> y = y'.
  Proof.
    intros.
    cut (proj (existT P x y) y = proj (existT P x y') y).
    simpl in |- *.
    case (eq_dec x x).
    intro e.
    elim e using K_dec; trivial.

    intros.
    case n; trivial.

    case H0.
    reflexivity.
  Defined.

  Lemma inj_right_pair_refl (P : A -> Type) (y : P x) :
    inj_right_pair (y:=y) (y':=y) (eq_refl _) = (eq_refl _).
  Proof. unfold inj_right_pair. intros. 
    unfold eq_rect. unfold proj. rewrite eq_dec_refl. 
    unfold K_dec. simpl.
    unfold eq_proofs_unicity. subst proj. 
    simpl. unfold nu_inv, comp, nu. simpl. 
    unfold eq_ind, nu_left_inv, trans_sym_eq, eq_rect, nu_constant.
    rewrite eq_dec_refl. reflexivity.
  Defined.

End EqdepDec.

Section PEqdepDec.
  Set Universe Polymorphism.
    
  Context {A : Type} `{EqDec A}.

  Let comp (x y y':A) (eq1:x = y) (eq2:x = y') : y = y' :=
    eq_ind _ (fun a => a = y') eq2 _ eq1.

  Remark ptrans_sym_eq : forall (x y:A) (u:x = y), comp u u = refl_equal y.
  Proof.
    intros.
    case u; trivial.
  Defined.

  Variable x : A.

  Let nu (y:A) (u:x = y) : x = y :=
    match eq_dec x y with
      | left eqxy => eqxy
      | right neqxy => False_ind _ (neqxy u)
    end.

  Let nu_constant : forall (y:A) (u v:x = y), nu u = nu v.
    intros.
    unfold nu in |- *.
    case (eq_dec x y); intros.
    reflexivity.

    case n; trivial.
  Defined.

  Let nu_inv (y:A) (v:x = y) : x = y := comp (nu (refl_equal x)) v.

  Remark pnu_left_inv : forall (y:A) (u:x = y), nu_inv (nu u) = u.
  Proof.
    intros.
    case u; unfold nu_inv in |- *.
    apply ptrans_sym_eq.
  Defined.

  Theorem peq_proofs_unicity : forall (y:A) (p1 p2:x = y), p1 = p2.
  Proof.
    intros.
    elim pnu_left_inv with (u := p1).
    elim pnu_left_inv with (u := p2).
    elim nu_constant with y p1 p2.
    reflexivity.
  Defined.

  Theorem pK_dec :
    forall P:x = x -> Prop, P (refl_equal x) -> forall p:x = x, P p.
  Proof.
    intros.
    elim peq_proofs_unicity with x (refl_equal x) p.
    trivial.
  Defined.

  Lemma peq_dec_refl : eq_dec x x = left _ (eq_refl x).
  Proof. case eq_dec. intros. f_equal. apply peq_proofs_unicity. 
    intro. congruence.
  Defined.

  (* On [sigma] *)
  
  Let projs (P:A -> Type) (exP:sigma A P) (def:P x) : P x :=
    match exP with
      | sigmaI _ x' prf =>
        match eq_dec x' x with
          | left eqprf => eq_rect x' P prf x eqprf
          | _ => def
        end
    end.

  Theorem inj_right_sigma :
    forall (P:A -> Type) (y y':P x),
      sigmaI P x y = sigmaI P x y' -> y = y'.
  Proof.
    intros.
    cut (projs (sigmaI P x y) y = projs (sigmaI P x y') y).
    unfold projs. 
    case (eq_dec x x).
    intro e.
    elim e using pK_dec. trivial.

    intros.
    case n; trivial.

    case H0.
    reflexivity.
  Defined.

  Lemma inj_right_sigma_refl (P : A -> Type) (y : P x) :
    inj_right_sigma (y:=y) (y':=y) (eq_refl _) = (eq_refl _).
  Proof. unfold inj_right_sigma. intros. 
    unfold eq_rect. unfold projs. rewrite peq_dec_refl. 
    unfold pK_dec. simpl.
    unfold peq_proofs_unicity. subst projs.
    simpl. unfold nu_inv, comp, nu. simpl.
    unfold eq_ind, nu_left_inv, ptrans_sym_eq, eq_rect, nu_constant.
    rewrite peq_dec_refl. reflexivity.
  Defined.

End PEqdepDec.

Arguments inj_right_sigma {A} {H} {x} P y y' e.

Instance eq_eqdec {A} `{EqDec A} : forall x y : A, EqDec (x = y).
Proof.
  intros. red. intros.
  exact (left (eq_proofs_unicity x0 y0)).
Defined.
