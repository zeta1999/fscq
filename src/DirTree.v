Require Import Bool.
Require Import Word.
Require Import BFile Bytes Rec Inode.
Require Import String.
Require Import FSLayout.
Require Import Pred.
Require Import Arith.
Require Import GenSepN.
Require Import List ListUtils.
Require Import Array.
Require Import FunctionalExtensionality.
Require Import DiskSet.
Require Import GenSepAuto.
Require Import Lock.
Require Import Errno.
Require Import DirCache.
Require Import Balloc.
Import ListNotations.
Require Import DirTreePath.
Require Import DirTreeDef.
Require Import DirTreePred.
Require Import DirTreeRep.
Require Import DirTreeSafe.
Require Import DirTreeNames.
Require Import DirTreeInodes.
Require Import WeakConversion.

Set Implicit Arguments.

Module SDIR := CacheOneDir.

Module DIRTREE.

  (* Programs *)

  Notation MSLL := BFILE.MSLL.
  Notation MSAlloc := BFILE.MSAlloc.
  Notation MSAllocC := BFILE.MSAllocC.
  Notation MSIAllocC := BFILE.MSIAllocC.
  Notation MSICache := BFILE.MSICache.
  Notation MSCache := BFILE.MSCache.
  Notation MSDBlocks := BFILE.MSDBlocks.


  Definition namei fsxp dnum (fnlist : list string) mscs :=
    let '(lxp, bxp, ibxp, ixp) := ((FSXPLog fsxp), (FSXPBlockAlloc fsxp),
                                   fsxp, (FSXPInode fsxp)) in
    let^ (mscs, inum, isdir, valid) <- ForEach fn fnrest fnlist
      Blockmem bm
      Hashmap hm
      Ghost [ mbase m sm F Fm IFs Ftop treetop freeinodes freeinode_pred ilist freeblocks mscs0 crash ]
      Loopvar [ mscs inum isdir valid ]
      Invariant
        LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn mbase m) (MSLL mscs) sm bm hm *
        exists tree bflist fndone,
        [[ fndone ++ fnrest = fnlist ]] *
        [[ valid = OK tt ->
           (Ftop * tree_pred_except ibxp fndone treetop * tree_pred ibxp tree * freeinode_pred)%pred (list2nmem bflist) ]] *
        [[ isError valid ->
           (Ftop * tree_pred ibxp treetop * freeinode_pred)%pred (list2nmem bflist) ]] *
        [[ (Fm * BFILE.rep bxp IFs ixp bflist ilist freeblocks (MSAllocC mscs) (MSCache mscs) (MSICache mscs) (MSDBlocks mscs) hm *
            IAlloc.rep BFILE.freepred ibxp freeinodes freeinode_pred (IAlloc.mk_memstate (MSLL mscs) (MSIAllocC mscs)))%pred
           (list2nmem m) ]] *
        [[ dnum = dirtree_inum treetop ]] *
        [[ valid = OK tt -> inum = dirtree_inum tree ]] *
        [[ valid = OK tt -> isdir = dirtree_isdir tree ]] *
        [[ valid = OK tt -> find_subtree fnlist treetop = find_subtree fnrest tree ]] *
        [[ valid = OK tt -> find_subtree fndone treetop = Some tree ]] *
        [[ isError valid -> find_subtree fnlist treetop = None ]] *
        [[ MSAlloc mscs = MSAlloc mscs0 ]] *
        [[ MSAllocC mscs = MSAllocC mscs0 ]]
      OnCrash
        crash
      Begin
        match valid with
        | Err e =>
          Ret ^(mscs, inum, isdir, Err e)
        | OK _ =>
          If (bool_dec isdir true) {
            let^ (mscs, r) <- SDIR.lookup lxp ixp inum fn mscs;;
            match r with
            | Some (inum, isdir) => Ret ^(mscs, inum, isdir, OK tt)
            | None => Ret ^(mscs, inum, isdir, Err ENOENT)
            end
          } else {
            Ret ^(mscs, inum, isdir, Err ENOTDIR)
          }
        end
    Rof ^(mscs, dnum, true, OK tt);;
    match valid with
    | OK _ =>
      Ret ^(mscs, OK (inum, isdir))
    | Err e =>
      Ret ^(mscs, Err e)
    end.

  Definition mkfile fsxp dnum name tag fms :=
    let '(lxp, bxp, ibxp, ixp) := ((FSXPLog fsxp), (FSXPBlockAlloc fsxp),
                                   fsxp, (FSXPInode fsxp)) in
    let '(al, alc, ialc, ms, icache, cache, dbcache) := (MSAlloc fms, MSAllocC fms, MSIAllocC fms, MSLL fms, MSICache fms, MSCache fms, MSDBlocks fms) in
    let^ (ms, oi) <- IAlloc.alloc lxp ibxp (IAlloc.mk_memstate ms ialc);;
    let fms := BFILE.mk_memstate al (IAlloc.MSLog ms) alc (IAlloc.MSCache ms) icache cache dbcache in
    match oi with
    | None => Ret ^(fms, Err ENOSPCINODE)
    | Some inum =>
      let^ (fms, ok) <- BFILE.setowner lxp ixp inum tag fms;;
      let^ (fms, ok) <- SDIR.link lxp bxp ixp dnum name inum false fms;;
      match ok with
      | OK _ =>
        Ret ^(fms, OK (inum : addr))
      | Err e =>
        Ret ^(fms, Err e)
      end
    end.


  Definition mkdir fsxp dnum name fms :=
    let '(lxp, bxp, ibxp, ixp) := ((FSXPLog fsxp), (FSXPBlockAlloc fsxp),
                                   fsxp, (FSXPInode fsxp)) in
    let '(al, alc, ialc, ms, icache, cache, dbcache) := (MSAlloc fms, MSAllocC fms, MSIAllocC fms, MSLL fms, MSICache fms, MSCache fms, MSDBlocks fms) in
    let^ (ms, oi) <- IAlloc.alloc lxp ibxp (IAlloc.mk_memstate ms ialc);;
    let fms := BFILE.mk_memstate al (IAlloc.MSLog ms) alc (IAlloc.MSCache ms) icache cache dbcache in
    match oi with
    | None => Ret ^(fms, Err ENOSPCINODE)
    | Some inum =>
      let^ (fms, ok) <- SDIR.link lxp bxp ixp dnum name inum true fms;;
      match ok with
      | OK _ =>
        Ret ^(fms, OK (inum : addr))
      | Err e =>
        Ret ^(fms, Err e)
      end
    end.


  Definition delete fsxp dnum name mscs :=
    let '(lxp, bxp, ibxp, ixp) := ((FSXPLog fsxp), (FSXPBlockAlloc fsxp),
                                   fsxp, (FSXPInode fsxp)) in
    let^ (mscs, oi) <- SDIR.lookup lxp ixp dnum name mscs;;
    match oi with
    | None => Ret ^(mscs, Err ENOENT)
    | Some (inum, isdir) =>
      let^ (mscs, ok) <- If (bool_dec isdir false) {
        Ret ^(mscs, true)
      } else {
        let^ (mscs, l) <- SDIR.readdir lxp ixp inum mscs;;
        match l with
        | nil => Ret ^(mscs, true)
        | _ => Ret ^(mscs, false)
        end
      };;
      If (bool_dec ok false) {
        Ret ^(mscs, Err ENOTEMPTY)
      } else {
        let^ (mscs, ok) <- SDIR.unlink lxp ixp dnum name mscs;;
        match ok with
        | OK _ =>
          mscs <- BFILE.reset lxp bxp ixp inum mscs;;
          mscs' <- IAlloc.free lxp ibxp inum (IAlloc.mk_memstate (MSLL mscs) (MSIAllocC mscs));;
          Ret ^(BFILE.mk_memstate (MSAlloc mscs) (IAlloc.MSLog mscs') (MSAllocC mscs) (IAlloc.MSCache mscs') (MSICache mscs) (MSCache mscs) (MSDBlocks mscs), OK tt)
        | Err e =>
          Ret ^(mscs, Err e)
        end
     }
    end.

  Definition rename fsxp dnum srcpath srcname dstpath dstname mscs :=
    let '(lxp, bxp, ibxp, ixp) := ((FSXPLog fsxp), (FSXPBlockAlloc fsxp),
                                   fsxp, (FSXPInode fsxp)) in
    let^ (mscs, osrcdir) <- namei fsxp dnum srcpath mscs;;
    match osrcdir with
    | Err _ => Ret ^(mscs, Err ENOENT)
    | OK (_, false) => Ret ^(mscs, Err ENOTDIR)
    | OK (dsrc, true) =>
      let^ (mscs, osrc) <- SDIR.lookup lxp ixp dsrc srcname mscs;;
      match osrc with
      | None => Ret ^(mscs, Err ENOENT)
      | Some (inum, inum_isdir) =>
        let^ (mscs, _) <- SDIR.unlink lxp ixp dsrc srcname mscs;;
        let^ (mscs, odstdir) <- namei fsxp dnum dstpath mscs;;
        match odstdir with
        | Err _ => Ret ^(mscs, Err ENOENT)
        | OK (_, false) => Ret ^(mscs, Err ENOTDIR)
        | OK (ddst, true) =>
          let^ (mscs, odst) <- SDIR.lookup lxp ixp ddst dstname mscs;;
          match odst with
          | None =>
            let^ (mscs, ok) <- SDIR.link lxp bxp ixp ddst dstname inum inum_isdir mscs;;
            Ret ^(mscs, ok)
          | Some _ =>
            let^ (mscs, ok) <- delete fsxp ddst dstname mscs;;
            match ok with
            | OK _ =>
              let^ (mscs, ok) <- SDIR.link lxp bxp ixp ddst dstname inum inum_isdir mscs;;
              Ret ^(mscs, ok)
            | Err e =>
              Ret ^(mscs, Err e)
            end
          end
        end
      end
    end.

  Definition read fsxp inum off mscs :=
    let^ (mscs, v) <- BFILE.read (FSXPLog fsxp) (FSXPInode fsxp) inum off mscs;;
    Ret ^(mscs, v).

  Definition write fsxp inum off v mscs :=
    mscs <- BFILE.write (FSXPLog fsxp) (FSXPInode fsxp) inum off v mscs;;
    Ret mscs.

  Definition dwrite fsxp inum off v mscs :=
    mscs <- BFILE.dwrite (FSXPLog fsxp) (FSXPInode fsxp) inum off v mscs;;
    Ret mscs.

  Definition datasync fsxp inum mscs :=
    mscs <- BFILE.datasync (FSXPLog fsxp) (FSXPInode fsxp) inum mscs;;
    Ret mscs.

  Definition sync fsxp mscs :=
    mscs <- BFILE.sync (FSXPLog fsxp) (FSXPInode fsxp) mscs;;
    Ret mscs.

  Definition sync_noop fsxp mscs :=
    mscs <- BFILE.sync_noop (FSXPLog fsxp) (FSXPInode fsxp) mscs;;
    Ret mscs.

  Definition truncate fsxp inum nblocks mscs :=
    let^ (mscs, ok) <- BFILE.truncate (FSXPLog fsxp) (FSXPBlockAlloc fsxp) (FSXPInode fsxp) inum nblocks mscs;;
    Ret ^(mscs, ok).

  Definition getlen fsxp inum mscs :=
    let^ (mscs, len) <- BFILE.getlen (FSXPLog fsxp) (FSXPInode fsxp) inum mscs;;
    Ret ^(mscs, len).

  Definition getattr fsxp inum mscs :=
    let^ (mscs, attr) <- BFILE.getattrs (FSXPLog fsxp) (FSXPInode fsxp) inum mscs;;
    Ret ^(mscs, attr).

  Definition getowner fsxp inum mscs :=
    let^ (mscs, ow) <- BFILE.getowner (FSXPLog fsxp) (FSXPInode fsxp) inum mscs;;
    Ret ^(mscs, ow).
       
  Definition changeowner fsxp inum tag mscs :=
    r <- BFILE.setowner (FSXPLog fsxp) (FSXPInode fsxp) inum tag mscs;;
    Ret r.
       
  Definition setattr fsxp inum attr mscs :=
    mscs <- BFILE.setattrs (FSXPLog fsxp) (FSXPInode fsxp) inum attr mscs;;
    Ret mscs.

  Definition updattr fsxp inum kv mscs :=
    mscs <- BFILE.updattr (FSXPLog fsxp) (FSXPInode fsxp) inum kv mscs;;
         Ret mscs.

  Definition authenticate fsxp inum mscs:=
    let^ (ams, t) <- BFILE.getowner (FSXPLog fsxp) (FSXPInode fsxp) inum mscs;;
    p <- Auth t;;
    Ret ^(ams, p).  

  (* Specs and proofs *)

  Local Hint Unfold SDIR.rep_macro rep : hoare_unfold.

    Theorem changeowner_ok :
    forall fsxp inum tag mscs pr,
    {~<W F mbase sm m pathname Fm Ftop tree f ilist frees,
    PERM:pr   
    PRE:bm, hm, LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn mbase m) (MSLL mscs) sm bm hm *
           [[ (Fm * rep fsxp Ftop tree ilist frees mscs sm hm)%pred (list2nmem m) ]] *
           [[ find_subtree pathname tree = Some (TreeFile inum f) ]] *
           [[ can_access pr (DFOwner f) ]]
    POST:bm', hm', RET:^(mscs', ok)
           ([[ ok = false ]] *
            LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn mbase m) (MSLL mscs') sm bm' hm' *
            [[ (Fm * rep fsxp Ftop tree ilist frees mscs' sm hm')%pred (list2nmem m) ]] *
            [[ hm' = hm ]]) \/      
           ([[ ok = true ]] * exists m' tree' f' ilist',
           LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn mbase m') (MSLL mscs') sm bm' hm' *
           [[ (Fm * rep fsxp Ftop tree' ilist' frees mscs' sm hm')%pred (list2nmem m') ]] *
           [[ tree' = update_subtree pathname (TreeFile inum f') tree ]] *
           [[ f' = mk_dirfile (DFData f) (DFAttr f) tag ]] *
           [[ MSAlloc mscs' = MSAlloc mscs ]] *
           [[ dirtree_safe ilist  (BFILE.pick_balloc frees  (MSAlloc mscs')) tree
                           ilist' (BFILE.pick_balloc frees  (MSAlloc mscs')) tree' ]] *
           [[ BFILE.treeseq_ilist_safe inum ilist ilist' ]] *
           [[ hm' = Mem.upd hm (S inum) tag ]] *
           [[ length (MapUtils.AddrMap.Map.elements (LOG.MSTxn (fst (MSLL mscs')))) <= (LogLen fsxp.(FSXPLog)) ]])
    CRASH:bm', hm',
           LOG.intact fsxp.(FSXPLog) F mbase sm bm' hm'
    W>~} changeowner fsxp inum tag mscs.
  Proof.
    unfold changeowner.
    intros. weakprestep.
    intros m Hm; destruct_lift Hm.
    assert (A: tree_names_distinct dummy7).
    eapply rep_tree_names_distinct with (m:= list2nmem dummy3).
    unfold rep; pred_apply; cancel.
    assert (A0: tree_inodes_distinct dummy7).
    eapply rep_tree_inodes_distinct with (m:= list2nmem dummy3).
    unfold rep; pred_apply; cancel.
    rewrite subtree_extract in * by eauto.
    cbn [tree_pred] in *. destruct_lifts.
    repeat eexists; pred_apply; norm.
    cancel.
    intuition.      
    pred_apply; cancel.
    pred_apply; cancel.
    simpl in *; eauto.

    weakstep.
    weakstep; msalloc_eq.
    cancel.
    or_l; cancel.
    
    erewrite <- subtree_fold by eauto.
    unfold tree_pred; cancel.

    weakstep; msalloc_eq.
    cancel.
    or_r; cancel.
    eauto.
    rewrite <- subtree_absorb by eauto.
    cancel.
    eapply dirlist_safe_subtree; eauto.
    apply dirtree_safe_file_trans; auto.
  Qed.
              

   Theorem authenticate_ok :
    forall fsxp inum mscs pr,
  {< F ds d sm pathname Fm Ftop tree f ilist frees,
  PERM:pr    
  PRE:bm, hm,
         LOG.rep (FSXPLog fsxp) F (LOG.ActiveTxn ds d) (MSLL mscs) sm bm hm *
         [[[ d ::: (Fm * rep fsxp Ftop tree ilist frees mscs sm hm) ]]] *
         [[ find_subtree pathname tree = Some (TreeFile inum f) ]]
  POST:bm', hm', RET:^(mscs',r)
         LOG.rep (FSXPLog fsxp) F (LOG.ActiveTxn ds d) (MSLL mscs') sm bm' hm' *
         [[[ d ::: (Fm * rep fsxp Ftop tree ilist frees mscs' sm hm') ]]] *
         [[ MSAlloc mscs' = MSAlloc mscs ]] *
         [[ MSCache mscs' = MSCache mscs ]] *
         [[ MSAllocC mscs' = MSAllocC mscs ]] *
         [[ MSIAllocC mscs' = MSIAllocC mscs ]] *
         (([[ r = true ]] * [[ can_access pr (DFOwner f) ]]) \/
          ([[ r = false ]] * [[ ~can_access pr (DFOwner f) ]]))
  CRASH:bm', hm',
         LOG.intact (FSXPLog fsxp) F ds sm bm' hm'
  >} authenticate fsxp inum mscs.
  Proof.
    unfold authenticate, rep.
    intros. prestep.
    intros m Hm; destruct_lift Hm.
    rewrite subtree_extract in * by eauto.
    cbn [tree_pred] in *. destruct_lifts.
    repeat eexists; pred_apply; norm.
    cancel.
    intuition.      
    pred_apply; cancel.
    pred_apply; cancel.
    
    simpl.
    step.
    step.
    step.
    erewrite LOG.rep_blockmem_subset; eauto; cancel.
    or_l; cancel.
    msalloc_eq; cancel.
    eauto.
    rewrite <- subtree_fold by eauto. pred_apply; cancel.

    step.
    erewrite LOG.rep_blockmem_subset; eauto; cancel.
    or_r; cancel.
    msalloc_eq; cancel.
    eauto.
    rewrite <- subtree_fold by eauto. pred_apply; cancel.
    
    rewrite <- H2; cancel; eauto.
    Unshelve.
    all: eauto.
  Qed.

  Theorem authenticate_ok' :
    forall fsxp inum mscs pr,
  {< e,
  PERM:pr    
  PRE:bm, hm,
         let '(F, ds, d, sm, pathname, Fm, Ftop, tree, f, ilist, frees) := e in
         LOG.rep (FSXPLog fsxp) F (LOG.ActiveTxn ds d) (MSLL mscs) sm bm hm *
         [[[ d ::: (Fm * rep fsxp Ftop tree ilist frees mscs sm hm) ]]] *
         [[ find_subtree pathname tree = Some (TreeFile inum f) ]]
  POST:bm', hm', RET:^(mscs',r)
         let '(F, ds, d, sm, pathname, Fm, Ftop, tree, f, ilist, frees) := e in
         LOG.rep (FSXPLog fsxp) F (LOG.ActiveTxn ds d) (MSLL mscs') sm bm' hm' *
         [[[ d ::: (Fm * rep fsxp Ftop tree ilist frees mscs' sm hm') ]]] *
         [[ MSAlloc mscs' = MSAlloc mscs ]] *
         [[ MSCache mscs' = MSCache mscs ]] *
         [[ MSAllocC mscs' = MSAllocC mscs ]] *
         [[ MSIAllocC mscs' = MSIAllocC mscs ]] *
         (([[ r = true ]] * [[ can_access pr (DFOwner f) ]]) \/
          ([[ r = false ]] * [[ ~can_access pr (DFOwner f) ]]))
  CRASH:bm', hm',
        let '(F, ds, d, sm, pathname, Fm, Ftop, tree, f, ilist, frees) := e in
        LOG.intact (FSXPLog fsxp) F ds sm bm' hm'
  >} authenticate fsxp inum mscs.
  Proof.
    intros; eapply pimpl_ok2.
    apply authenticate_ok.
    intros; norml; simpl.
    safecancel.
    apply sep_star_comm.
    eauto.
    specialize (H2 (a, (a0, b0))); simpl in *; eauto.
  Qed.

  
  
  Theorem authenticate_ok_weak' :
    forall fsxp inum mscs pr,
  {<W e,
  PERM:pr    
  PRE:bm, hm,
         let '(F, ds, d, sm, pathname, Fm, Ftop, tree, f, ilist, frees) := e in
         LOG.rep (FSXPLog fsxp) F (LOG.ActiveTxn ds d) (MSLL mscs) sm bm hm *
         [[[ d ::: (Fm * rep fsxp Ftop tree ilist frees mscs sm hm) ]]] *
         [[ find_subtree pathname tree = Some (TreeFile inum f) ]]
  POST:bm', hm', RET:^(mscs',r)
         let '(F, ds, d, sm, pathname, Fm, Ftop, tree, f, ilist, frees) := e in
         LOG.rep (FSXPLog fsxp) F (LOG.ActiveTxn ds d) (MSLL mscs') sm bm' hm' *
         [[[ d ::: (Fm * rep fsxp Ftop tree ilist frees mscs' sm hm') ]]] *
         [[ MSAlloc mscs' = MSAlloc mscs ]] *
         [[ MSCache mscs' = MSCache mscs ]] *
         [[ MSAllocC mscs' = MSAllocC mscs ]] *
         [[ MSIAllocC mscs' = MSIAllocC mscs ]] *
         (([[ r = true ]] * [[ can_access pr (DFOwner f) ]]) \/
          ([[ r = false ]] * [[ ~can_access pr (DFOwner f) ]]))
  CRASH:bm', hm',
        let '(F, ds, d, sm, pathname, Fm, Ftop, tree, f, ilist, frees) := e in
        LOG.intact (FSXPLog fsxp) F ds sm bm' hm'
  W>} authenticate fsxp inum mscs.
  Proof.
    intros; eapply weak_conversion'.
    intros; apply authenticate_ok'.
  Qed.
  
   Theorem authenticate_ok_weak :
    forall fsxp inum mscs pr,
  {<W F ds d sm pathname Fm Ftop tree f ilist frees,
  PERM:pr    
  PRE:bm, hm,
         LOG.rep (FSXPLog fsxp) F (LOG.ActiveTxn ds d) (MSLL mscs) sm bm hm *
         [[[ d ::: (Fm * rep fsxp Ftop tree ilist frees mscs sm hm) ]]] *
         [[ find_subtree pathname tree = Some (TreeFile inum f) ]]
  POST:bm', hm', RET:^(mscs',r)
         LOG.rep (FSXPLog fsxp) F (LOG.ActiveTxn ds d) (MSLL mscs') sm bm' hm' *
         [[[ d ::: (Fm * rep fsxp Ftop tree ilist frees mscs' sm hm') ]]] *
         [[ MSAlloc mscs' = MSAlloc mscs ]] *
         [[ MSCache mscs' = MSCache mscs ]] *
         [[ MSAllocC mscs' = MSAllocC mscs ]] *
         [[ MSIAllocC mscs' = MSIAllocC mscs ]] *
         (([[ r = true ]] * [[ can_access pr (DFOwner f) ]]) \/
          ([[ r = false ]] * [[ ~can_access pr (DFOwner f) ]]))
  CRASH:bm', hm',
         LOG.intact (FSXPLog fsxp) F ds sm bm' hm'
  W>} authenticate fsxp inum mscs.
  Proof.
    intros; eapply pimpl_ok2_weak.
    apply authenticate_ok_weak'.
    intros; norml; simpl.
    safecancel.
    safecancel.
    apply sep_star_comm.
    eauto.
    eauto.
    specialize (H2 (a, (a0, b0))); simpl in *; eauto.
    eauto.
  Qed.
  
    
  Hint Extern 1 ({{_|_}} Bind (authenticate _ _ _) _) => apply authenticate_ok : prog.
  Hint Extern 1 ({{W _|_ W}} Bind (authenticate _ _ _) _) => apply authenticate_ok_weak : prog.

  Theorem getowner_ok :
    forall fsxp inum mscs pr,
    {< F ds sm d pathname Fm Ftop tree f ilist frees,
    PERM:pr   
    PRE:bm, hm, LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn ds d) (MSLL mscs) sm bm hm *
           [[[ d ::: Fm * rep fsxp Ftop tree ilist frees mscs sm hm ]]] *
           [[ find_subtree pathname tree = Some (TreeFile inum f) ]]
    POST:bm', hm', RET:^(mscs',r)
           LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn ds d) (MSLL mscs') sm bm' hm' *
           [[[ d ::: Fm * rep fsxp Ftop tree ilist frees mscs' sm hm' ]]] *
           [[ MSAlloc mscs' = MSAlloc mscs ]] *
           [[ MSCache mscs' = MSCache mscs ]] *
           [[ MSAllocC mscs' = MSAllocC mscs ]] *
           [[ MSIAllocC mscs' = MSIAllocC mscs ]] *
           [[ r = DFOwner f ]]
    CRASH:bm', hm',
           LOG.intact fsxp.(FSXPLog) F ds sm bm' hm'
    >} getowner fsxp inum mscs.
  Proof. 
    unfold getowner, rep.
    intros. prestep.
    intros m Hm; destruct_lift Hm.
    rewrite subtree_extract in * by eauto.
    cbn [tree_pred] in *. destruct_lifts.
    repeat eexists; pred_apply; norm.
    cancel.
    intuition.      
    pred_apply; cancel.
    pred_apply; cancel.

    step.
    step.
    msalloc_eq; cancel.
    eauto.
    rewrite <- subtree_fold by eauto. pred_apply; cancel.
    rewrite<- H2; cancel; eauto.
  Qed.

  Theorem getowner_ok' :
    forall fsxp inum mscs pr,
    {< e,
    PERM:pr   
    PRE:bm, hm,
           let '(F, ds, d, sm, pathname, Fm, Ftop, tree, f, ilist, frees) := e in
           LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn ds d) (MSLL mscs) sm bm hm *
           [[[ d ::: Fm * rep fsxp Ftop tree ilist frees mscs sm hm ]]] *
           [[ find_subtree pathname tree = Some (TreeFile inum f) ]]
    POST:bm', hm', RET:^(mscs',r)
           let '(F, ds, d, sm, pathname, Fm, Ftop, tree, f, ilist, frees) := e in
           LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn ds d) (MSLL mscs') sm bm' hm' *
           [[[ d ::: Fm * rep fsxp Ftop tree ilist frees mscs' sm hm' ]]] *
           [[ MSAlloc mscs' = MSAlloc mscs ]] *
           [[ MSCache mscs' = MSCache mscs ]] *
           [[ MSAllocC mscs' = MSAllocC mscs ]] *
           [[ MSIAllocC mscs' = MSIAllocC mscs ]] *
           [[ r = DFOwner f ]]
    CRASH:bm', hm',
           let '(F, ds, d, sm, pathname, Fm, Ftop, tree, f, ilist, frees) := e in
           LOG.intact fsxp.(FSXPLog) F ds sm bm' hm'
    >} getowner fsxp inum mscs.
  Proof.
    intros; eapply pimpl_ok2.
    apply getowner_ok.
    intros; norml; simpl.
    safecancel.
    apply sep_star_comm.
    eauto.
    specialize (H2 (a, (a0, b0))); simpl in *; eauto.
  Qed.

  Theorem getowner_ok_weak' :
    forall fsxp inum mscs pr,
    {<W e,
    PERM:pr   
    PRE:bm, hm,
           let '(F, ds, d, sm, pathname, Fm, Ftop, tree, f, ilist, frees) := e in
           LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn ds d) (MSLL mscs) sm bm hm *
           [[[ d ::: Fm * rep fsxp Ftop tree ilist frees mscs sm hm ]]] *
           [[ find_subtree pathname tree = Some (TreeFile inum f) ]]
    POST:bm', hm', RET:^(mscs',r)
           let '(F, ds, d, sm, pathname, Fm, Ftop, tree, f, ilist, frees) := e in
           LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn ds d) (MSLL mscs') sm bm' hm' *
           [[[ d ::: Fm * rep fsxp Ftop tree ilist frees mscs' sm hm' ]]] *
           [[ MSAlloc mscs' = MSAlloc mscs ]] *
           [[ MSCache mscs' = MSCache mscs ]] *
           [[ MSAllocC mscs' = MSAllocC mscs ]] *
           [[ MSIAllocC mscs' = MSIAllocC mscs ]] *
           [[ r = DFOwner f ]]
    CRASH:bm', hm',
           let '(F, ds, d, sm, pathname, Fm, Ftop, tree, f, ilist, frees) := e in
           LOG.intact fsxp.(FSXPLog) F ds sm bm' hm'
    W>} getowner fsxp inum mscs.
  Proof.
    intros; eapply weak_conversion'.
    intros; apply getowner_ok'.
  Qed.

  Theorem getowner_ok_weak :
    forall fsxp inum mscs pr,
    {<W F ds sm d pathname Fm Ftop tree f ilist frees,
    PERM:pr   
    PRE:bm, hm, LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn ds d) (MSLL mscs) sm bm hm *
           [[[ d ::: Fm * rep fsxp Ftop tree ilist frees mscs sm hm ]]] *
           [[ find_subtree pathname tree = Some (TreeFile inum f) ]]
    POST:bm', hm', RET:^(mscs',r)
           LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn ds d) (MSLL mscs') sm bm' hm' *
           [[[ d ::: Fm * rep fsxp Ftop tree ilist frees mscs' sm hm' ]]] *
           [[ MSAlloc mscs' = MSAlloc mscs ]] *
           [[ MSCache mscs' = MSCache mscs ]] *
           [[ MSAllocC mscs' = MSAllocC mscs ]] *
           [[ MSIAllocC mscs' = MSIAllocC mscs ]] *
           [[ r = DFOwner f ]]
    CRASH:bm', hm',
           LOG.intact fsxp.(FSXPLog) F ds sm bm' hm'
    W>} getowner fsxp inum mscs.
  Proof. 
    intros; eapply pimpl_ok2_weak.
    apply getowner_ok_weak'.
    intros; norml; simpl.
    safecancel.
    safecancel.
    apply sep_star_comm.
    eauto.
    eauto.
    specialize (H2 (a, (a0, b0))); simpl in *; eauto.
    eauto.
  Qed.
  
  Theorem namei_ok :
    forall fsxp dnum fnlist mscs pr,
    {< F mbase m sm Fm Ftop tree ilist freeblocks,
    PERM:pr                    
    PRE:bm, hm, LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn mbase m) (MSLL mscs) sm bm hm *
           [[ (Fm * rep fsxp Ftop tree ilist freeblocks mscs sm hm)%pred (list2nmem m) ]] *
           [[ dnum = dirtree_inum tree ]] *
           [[ dirtree_isdir tree = true ]]
    POST:bm', hm', RET:^(mscs',r)
           LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn mbase m) (MSLL mscs') sm bm' hm' *
           [[ (Fm * rep fsxp Ftop tree ilist freeblocks mscs' sm hm')%pred (list2nmem m) ]] *
           [[ (isError r /\ None = find_name fnlist tree) \/
              (exists v, (r = OK v /\ Some v = find_name fnlist tree))%type ]] *
           [[ MSAlloc mscs' = MSAlloc mscs ]]
    CRASH:bm', hm',
           LOG.intact fsxp.(FSXPLog) F mbase sm bm' hm'
    >} namei fsxp dnum fnlist mscs.
  Proof. 
    unfold namei.
    step.

    (* Prove loop entry: fndone = nil *)
    rewrite app_nil_l; eauto.
    pred_apply; cancel.
    reflexivity.

    assert (tree_names_distinct tree).
    eapply rep_tree_names_distinct with (m := list2nmem m).
    pred_apply. unfold rep. cancel.

    (* Lock up the initial memory description, because our memory stays the
     * same, and without this lock-up, we end up with several distinct facts
     * about the same memory.
     *)

    all: denote! (_ (list2nmem m)) as Hm0; rewrite <- locked_eq in Hm0.

    destruct_branch.
    step.

    (* isdir = true *)
    destruct tree0; simpl in *; subst; intuition.
    step.
    denote (tree_dir_names_pred) as Hx.
    unfold tree_dir_names_pred in Hx; destruct_lift Hx.
    safestep; eauto.

    (* Lock up another copy of a predicate about our running memory. *)
    denote! (_ (list2nmem m)) as Hm1; rewrite <- locked_eq in Hm1.
    denote (dirlist_pred) as Hx; assert (Horig := Hx).

    destruct_branch.

    (* dslookup = Some _: extract subtree before [cancel] *)
    step.
    prestep.
    norml; unfold stars; simpl; inv_option_eq.
    destruct a2.

    (* subtree is a directory *)
    rewrite tree_dir_extract_subdir in Hx by eauto; destruct_lift Hx.
    norm. cancel. intuition simpl.
    intuition simpl.
    rewrite cons_app. rewrite app_assoc. reflexivity.

    3: pred_apply; cancel.
    pred_apply; cancel.
    eapply pimpl_trans; [ eapply pimpl_trans | ].
    2: eapply subtree_absorb with
          (xp := fsxp) (fnlist := fndone) (tree := tree)
          (subtree := TreeDir n l0) (subtree' := TreeDir n l0); eauto.
    simpl; unfold tree_dir_names_pred; cancel; eauto.

    rewrite update_subtree_same; eauto.

    eapply pimpl_trans.
    eapply subtree_extract with
          (xp := fsxp) (fnlist := fndone ++ [elem])
          (subtree := TreeDir a1 dummy5).

    erewrite find_subtree_app by eauto.
    eauto.
    reflexivity.

    pred_apply; cancel.
    msalloc_eq; cancel.
    auto. auto.
    rewrite cons_app. rewrite app_assoc.
    erewrite find_subtree_app. reflexivity.
    erewrite find_subtree_app by eauto. eauto.
    erewrite find_subtree_app by eauto. eauto.
    eauto.
    eauto.
    msalloc_eq; eauto.
    msalloc_eq; eauto.
    eauto. eauto.
    
    
    (* subtree is a file *)
    rewrite tree_dir_extract_file in Hx by eauto. destruct_lift Hx.
    norm; unfold stars; simpl. cancel.
    intuition idtac.
    rewrite cons_app. rewrite app_assoc. reflexivity.
    3: pred_apply; cancel.
    pred_apply; cancel.
    eassign (TreeFile a1 dummy5).
    3: auto. 3: auto.

    eapply pimpl_trans; [ eapply pimpl_trans | ].
    2: eapply subtree_absorb with
          (xp := fsxp) (fnlist := fndone) (tree := tree)
          (subtree := TreeDir n l0) (subtree' := TreeDir n l0); eauto.
    simpl; unfold tree_dir_names_pred; cancel; eauto.

    rewrite update_subtree_same; eauto.

    eapply pimpl_trans.
    eapply subtree_extract with
          (xp := fsxp) (fnlist := fndone ++ [elem])
          (subtree := TreeFile a1 dummy5).

    erewrite find_subtree_app by eauto.
    eauto.
    reflexivity.

    pred_apply; cancel.
    msalloc_eq; eauto.
    auto.
    auto.

    rewrite cons_app. rewrite app_assoc.
    erewrite find_subtree_app. reflexivity.

    erewrite find_subtree_app by eauto. eauto.
    erewrite find_subtree_app by eauto. eauto.
    eauto.
    msalloc_eq; eauto.
    msalloc_eq; eauto.
    eauto. eauto.
    
    (* dslookup = None *)
    step.
    prestep. norm; msalloc_eq. cancel.
    intuition idtac.
    all: try solve [ exfalso; congruence ].
    rewrite cons_app. rewrite app_assoc. reflexivity.
    2: pred_apply; cancel.
    pred_apply; cancel.

    eapply pimpl_trans; [ | eapply pimpl_trans ].
    2: eapply subtree_absorb with (xp := fsxp) (fnlist := fndone) (tree := tree) (subtree' := TreeDir n l0).
    cancel. unfold tree_dir_names_pred. cancel; eauto.
    eauto. eauto. eauto.

    rewrite update_subtree_same by eauto. cancel.
    erewrite <- find_subtree_none; eauto.
    eauto. eauto.
    rewrite <- H1; cancel; eauto.

    step.
    prestep. norm; msalloc_eq.
    cancel; erewrite LOG.rep_hashmap_subset; eauto.
    intuition idtac.
    rewrite cons_app. rewrite app_assoc. reflexivity.
    all: try solve [ exfalso; congruence ].
    2: pred_apply; cancel.
    pred_apply; cancel.

    eapply pimpl_trans; [ | eapply pimpl_trans ].
    2: eapply subtree_absorb with (xp := fsxp) (fnlist := fndone) (tree := tree) (subtree' := tree0).
    cancel. eauto. eauto. eauto.
    rewrite update_subtree_same by eauto. cancel.
    denote (find_subtree) as Hx; rewrite Hx.
    destruct tree0; intuition.
    eauto.

    step.
    step.
    rewrite cons_app. rewrite app_assoc. reflexivity.

    (* Ret : OK *)
    assert (tree_names_distinct tree).
    eapply rep_tree_names_distinct with (m := locked (list2nmem m)).
    pred_apply. unfold rep. cancel.

    step; safestep; msalloc_eq.
    rewrite sep_star_comm.
    rewrite subtree_absorb.
    rewrite update_subtree_same.
    cancel.
    all: eauto.

    right; eexists; intuition.
    denote! (find_subtree (fndone ++ _) _ = _) as Hx.
    unfold find_name; rewrite Hx.
    destruct tree0; reflexivity.

    left; intuition.
    denote (find_subtree (fndone ++ _) _ = _) as Hx.
    unfold find_name; rewrite Hx; eauto.
    eassign (false_pred(AT:=addr)(AEQ:=addr_eq_dec)(V:=valuset)).
    unfold false_pred; cancel. 

    Grab Existential Variables.
    all: try congruence.
    all: try exact unit.
    all: try exact None; eauto.
    all: intros; try exact tt.
   Qed.

  Hint Extern 1 ({{_|_}} Bind (namei _ _ _ _) _) => apply namei_ok : prog.

  Theorem mkdir_ok' :
    forall fsxp dnum name mscs pr,
    {< F mbase m sm Fm Ftop tree tree_elem ilist freeblocks,
    PERM:pr   
    PRE:bm, hm,
           LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn mbase m) (MSLL mscs) sm bm hm *
           [[ (Fm * rep fsxp Ftop tree ilist freeblocks mscs sm hm)%pred (list2nmem m) ]] *
           [[ tree = TreeDir dnum tree_elem ]]
    POST:bm', hm', RET:^(mscs',r)
           exists m', LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn mbase m') (MSLL mscs') sm bm' hm' *
           [[ MSAlloc mscs' = MSAlloc mscs ]] *
           ([[ isError r ]] \/
            exists inum ilist' freeblocks',
            let tree' := TreeDir dnum ((name, TreeDir inum nil) :: tree_elem) in
            [[ r = OK inum ]] *
            [[ (Fm * rep fsxp Ftop tree' ilist' freeblocks' mscs' sm hm')%pred (list2nmem m') ]] *
            [[ BFILE.treeseq_ilist_safe dnum ilist ilist' ]] *
            [[ dirtree_safe ilist  (BFILE.pick_balloc freeblocks  (MSAlloc mscs')) tree
                            ilist' (BFILE.pick_balloc freeblocks' (MSAlloc mscs')) tree' ]] )
    CRASH:bm', hm',
           LOG.intact fsxp.(FSXPLog) F mbase sm bm' hm'
    >} mkdir fsxp dnum name mscs.
  Proof. 
    unfold mkdir, rep.
    step.
    destruct_branch.
    denote tree_dir_names_pred as Hx;
    unfold tree_dir_names_pred in Hx; destruct_lift Hx.
    unfold IAlloc.MSLog in *.
    step.
    eapply IAlloc.ino_valid_goodSize; eauto.
    destruct_branch.
    safestep.
    prestep; norml; inv_option_eq; msalloc_eq.

    cancel.
    match goal with a: IAlloc.Alloc.memstate |- _
      => destruct a; cbn in *; subst
    end.
    or_r; cancel.
    unfold tree_dir_names_pred at 1. cancel; eauto.
    denote (dummy1 =p=> _) as Hx. rewrite Hx.
    unfold tree_dir_names_pred; cancel.
    denote (BFILE.freepred _) as Hy. unfold BFILE.freepred in Hy. subst.
    apply SDIR.bfile0_empty.
    apply emp_empty_mem.
    apply sep_star_comm. apply ptsto_upd_disjoint. auto. auto.
    
    eapply dirlist_safe_mkdir; auto.
    eauto.
    cancel.
    step. step.

    rewrite <- H1; cancel; eauto.
    step. step.
    erewrite LOG.rep_hashmap_subset; eauto; unfold IAlloc.MSLog; cancel.
    or_l; cancel.
 
    Unshelve.
    all: try eauto; exact emp; try exact nil;
    try exact empty_mem; try exact BFILE.bfile0.
  Qed.

  
  Theorem mkdir_ok :
    forall fsxp dnum name mscs pr,
    {< F mbase sm m pathname Fm Ftop tree tree_elem ilist frees,
    PERM: pr 
    PRE:bm, hm,
        LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn mbase m) (MSLL mscs) sm bm hm *
        [[ (Fm * rep fsxp Ftop tree ilist frees mscs sm hm)%pred (list2nmem m) ]] *
        [[ find_subtree pathname tree = Some (TreeDir dnum tree_elem) ]]
    POST:bm', hm', RET:^(mscs',r) exists m',
        LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn mbase m') (MSLL mscs') sm bm' hm' *
        [[ MSAlloc mscs' = MSAlloc mscs ]] *
        ([[ isError r ]] \/
         exists inum tree' ilist' frees',
         [[ r = OK inum ]] *
         [[ tree' = update_subtree pathname (TreeDir dnum
                       ((name, TreeDir inum nil) :: tree_elem)) tree ]] *
         [[ (Fm * rep fsxp Ftop tree' ilist' frees' mscs' sm hm')%pred (list2nmem m') ]] *
         [[ dirtree_safe ilist  (BFILE.pick_balloc frees  (MSAlloc mscs')) tree
                         ilist' (BFILE.pick_balloc frees' (MSAlloc mscs')) tree' ]] )
    CRASH:bm', hm',
           LOG.intact fsxp.(FSXPLog) F mbase sm bm' hm'
    >} mkdir fsxp dnum name mscs.
  Proof. 
    intros; eapply pimpl_ok2. apply mkdir_ok'.
    unfold rep; cancel.
    rewrite subtree_extract; eauto. simpl. instantiate (tree_elem0 := tree_elem). cancel.

    step.
    apply pimpl_or_r; right. cancel.
    rewrite <- subtree_absorb; eauto.
    cancel.
    eapply dirlist_safe_subtree; eauto.
  Qed.


  Theorem mkfile_ok' :
    forall fsxp dnum name tag mscs pr,
    {< F mbase sm m pathname Fm Ftop tree tree_elem ilist frees,
    PERM:pr   
    PRE:bm, hm, LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn mbase m) (MSLL mscs) sm bm hm *
           [[ (Fm * rep fsxp Ftop tree ilist frees mscs sm hm)%pred (list2nmem m) ]] *
           [[ find_subtree pathname tree = Some (TreeDir dnum tree_elem) ]]
    POST:bm', hm', RET:^(mscs',r) exists m',
           LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn mbase m') (MSLL mscs') sm bm' hm' *
           [[ MSAlloc mscs' = MSAlloc mscs ]] *
           ([[ isError r ]] \/
            exists inum ilist' tree' frees',
            let dfile0:= {| DFData := [];
                            DFAttr := INODE.iattr0;
                            DFOwner:= tag |} in
            [[ r = OK inum ]] * [[ ~ In name (map fst tree_elem) ]] *
            [[ tree' = update_subtree pathname (TreeDir dnum
                        (tree_elem ++ [(name, (TreeFile inum dfile0))] )) tree ]] *
            [[ (Fm * rep fsxp Ftop tree' ilist' frees' mscs' sm hm')%pred (list2nmem m') ]] *
            [[ dirtree_safe ilist  (BFILE.pick_balloc frees  (MSAlloc mscs')) tree
                            ilist' (BFILE.pick_balloc frees' (MSAlloc mscs')) tree' ]])
    CRASH:bm', hm',
           LOG.intact fsxp.(FSXPLog) F mbase sm bm' hm'
    >} mkfile fsxp dnum name tag mscs.
  Proof. 
    unfold mkfile, rep.
    step.
    subst; simpl in *.

    denote tree_pred as Ht;
    rewrite subtree_extract in Ht; eauto.
    assert (tree_names_distinct (TreeDir dnum tree_elem)).
    eapply rep_tree_names_distinct with (m := list2nmem m).
    pred_apply; unfold rep; cancel.

    simpl in *.
    denote tree_dir_names_pred as Hx;
    unfold tree_dir_names_pred in Hx; destruct_lift Hx.
    unfold IAlloc.MSLog in *.
    destruct_branch.
    prestep; norml; try congruence.
    unfold BFILE.freepred in *.
    
    rewrite H17 in H4; destruct_lift H4; subst.
    norm.
    cancel.
    intuition.
    pred_apply; cancel.
    cleanup; pred_apply; cancel.
    unfold BFILE.bfile0; eauto.

    lightstep.
    eassign dummy7.
    destruct (Nat.eq_dec n dnum); subst.
    exfalso; eapply ptsto_conflict_F with (m:=list2nmem dummy5)(a:=dnum).
    pred_apply; cancel.
    msalloc_eq.
    pred_apply; cancel.
    pred_apply; cancel.
    unfold SDIR.rep_macro in *.
    eapply IAlloc.ino_valid_goodSize; eauto.    
    cleanup; eauto.
    cleanup; eauto.

    destruct_branch.
    step.
    prestep; norml; inv_option_eq.

    cancel.
    match goal with a: IAlloc.Alloc.memstate |- _
      => destruct a; cbn in *; subst
    end.
    msalloc_eq.
    or_r; cancel.
    eapply dirname_not_in; eauto.

    rewrite <- subtree_absorb; eauto.
    cancel.
    unfold tree_dir_names_pred.
    cancel; eauto.
    rewrite dirlist_pred_split; simpl; cancel.

    apply tree_dir_names_pred'_app; simpl.
    apply sep_star_assoc; apply emp_star_r.
    apply ptsto_upd_disjoint; auto.

    eapply dirlist_safe_subtree; eauto.
    msalloc_eq.
    eapply dirlist_safe_mkfile; eauto.
    unfold INODE.iattr0; simpl; pred_apply; cancel.
    eapply BFILE.ilist_safe_trans; eauto.
    eapply dirname_not_in; eauto.
    eauto.

    step.
    step.

    all: try solve [rewrite <- H1; cancel; eauto].

    step.
    step.

    Unshelve.
    all: eauto.
 Qed.

  Hint Extern 0 (okToUnify (rep _ _ _ _ _ _ _) (rep _ _ _ _ _ _ _)) => constructor : okToUnify.


  (* same as previous one, but use tree_graft *)
  Theorem mkfile_ok :
    forall fsxp dnum name mscs tag pr,
    {< F mbase sm m pathname Fm Ftop tree tree_elem ilist frees,
    PERM:pr   
    PRE:bm, hm, LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn mbase m) (MSLL mscs) sm bm hm *
           [[ (Fm * rep fsxp Ftop tree ilist frees mscs sm hm)%pred (list2nmem m) ]] *
           [[ find_subtree pathname tree = Some (TreeDir dnum tree_elem) ]]
    POST:bm', hm', RET:^(mscs',r) exists m',
           LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn mbase m') (MSLL mscs') sm bm' hm' *
           [[ MSAlloc mscs' = MSAlloc mscs ]] *
           ([[ isError r ]] \/
            exists inum ilist' tree' frees',
             let dfile0:= {| DFData := [];
                            DFAttr := INODE.iattr0;
                            DFOwner:= tag|} in
            [[ r = OK inum ]] *
            [[ tree' = tree_graft dnum tree_elem pathname name (TreeFile inum dfile0) tree ]] *
            [[ (Fm * rep fsxp Ftop tree' ilist' frees' mscs' sm hm')%pred (list2nmem m') ]] *
            [[ dirtree_safe ilist  (BFILE.pick_balloc frees  (MSAlloc mscs')) tree
                            ilist' (BFILE.pick_balloc frees' (MSAlloc mscs')) tree' ]])
    CRASH:bm', hm',
           LOG.intact fsxp.(FSXPLog) F mbase sm bm' hm'
    >} mkfile fsxp dnum name tag mscs.
  Proof. 
    unfold mkfile; intros.
    eapply pimpl_ok2. apply mkfile_ok'.
    cancel.
    eauto.
    step.

    or_r; cancel.
    rewrite tree_graft_not_in_dirents; auto.
    rewrite <- tree_graft_not_in_dirents; auto.
  Qed.


  Hint Extern 1 ({{_|_}} Bind (mkdir _ _ _ _) _) => apply mkdir_ok : prog.
  Hint Extern 1 ({{_|_}} Bind (mkfile _ _ _ _ _) _) => apply mkfile_ok : prog.

  Lemma false_False_true : forall x,
    (x = false -> False) -> x = true.
  Proof.
    destruct x; tauto.
  Qed.

  Lemma true_False_false : forall x,
    (x = true -> False) -> x = false.
  Proof.
    destruct x; tauto.
  Qed.

  Ltac subst_bool :=
    repeat match goal with
    | [ H : ?x = true |- _ ] => is_var x; subst x
    | [ H : ?x = false |- _ ] => is_var x; subst x
    | [ H : ?x = false -> False  |- _ ] => is_var x; apply false_False_true in H; subst x
    | [ H : ?x = true -> False   |- _ ] => is_var x; apply true_False_false in H; subst x
    end.


  Hint Extern 0 (okToUnify (tree_dir_names_pred _ _ _) (tree_dir_names_pred _ _ _)) => constructor : okToUnify.

  Theorem delete_ok' :
    forall fsxp dnum name mscs pr,
    {< F mbase sm m Fm Ftop tree tree_elem frees ilist,
    PERM:pr  
    PRE:bm, hm, LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn mbase m) (MSLL mscs) sm bm hm *
           [[ (Fm * rep fsxp Ftop tree ilist frees mscs sm hm)%pred (list2nmem m) ]] *
           [[ tree = TreeDir dnum tree_elem ]]
    POST:bm', hm', RET:^(mscs',r)
           exists m', LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn mbase m') (MSLL mscs') sm bm' hm' *
           [[ MSAlloc mscs' = MSAlloc mscs ]] *
           ([[ isError r ]] \/
            [[ r = OK tt ]] * exists frees' ilist',
            let tree' := delete_from_dir name tree in
            [[ (Fm * rep fsxp Ftop tree' ilist' frees' mscs' sm hm')%pred (list2nmem m') ]] *
            [[ dirtree_safe ilist  (BFILE.pick_balloc frees  (MSAlloc mscs')) tree
                            ilist' (BFILE.pick_balloc frees' (MSAlloc mscs')) tree' ]] *
            [[ forall inum def', inum <> dnum ->
                 (In inum (tree_inodes tree') \/ (~ In inum (tree_inodes tree))) -> selN ilist inum def' = selN ilist' inum def' ]])
    CRASH:bm', hm',
           LOG.intact fsxp.(FSXPLog) F mbase sm bm' hm'
    >} delete fsxp dnum name mscs.
  Proof. 
    unfold delete, rep.

    (* extract some basic facts from rep *)
    intros; eapply pimpl_ok2; monad_simpl; eauto with prog; intros; norm'l.
    assert (tree_inodes_distinct (TreeDir dnum tree_elem)) as HiID.
    eapply rep_tree_inodes_distinct with (m := list2nmem m).
    pred_apply; unfold rep; cancel.
    assert (tree_names_distinct (TreeDir dnum tree_elem)) as HdID.
    eapply rep_tree_names_distinct with (m := list2nmem m).
    pred_apply; unfold rep; cancel.

    (* lookup *)
    subst; simpl in *.
    denote tree_dir_names_pred as Hx;
    unfold tree_dir_names_pred in Hx; destruct_lift Hx.
    safecancel. 2: eauto.
    unfold SDIR.rep_macro.
    cancel; eauto.
    

    denote! (_ (list2nmem m)) as Hm0; rewrite <- locked_eq in Hm0.
    step.
    step.
    step.
    step.

    (* unlink *)
    prestep.
    erewrite LOG.rep_hashmap_subset; eauto.
    norm.
    cancel.
    intuition.
    eauto.
    eauto.
    eauto.
    eauto.

    (* is_file: prepare for reset *)
    prestep. norml.
    denote dirlist_pred as Hx.
    erewrite dirlist_extract with (inum := a0) in Hx; eauto.
    destruct_lift Hx.
    destruct dummy4; simpl in *; try congruence; subst.
    denote dirlist_pred_except as Hx; destruct_lift Hx; auto.
    cancel.

    (* is_file: prepare for free *)
    prestep. norml; msalloc_eq.
    denote dirlist_pred as Hx.
    (*erewrite dirlist_extract with (inum := n) in Hx; eauto. *)
    destruct_lift Hx.
    denote dirlist_pred_except as Hx; destruct_lift Hx; auto.
    unfold IAlloc.MSLog in *; cancel.
    match goal with H: (_ * ptsto ?a _)%pred ?m |- context [ptsto ?a]
      => exists m; solve [pred_apply; cancel]
    end.

    (* post conditions *)
    step.
    step.
    or_r; safecancel.
    
    denote (pimpl _ freepred') as Hx; rewrite <- Hx.
    rewrite dir_names_delete with (dnum := dnum); eauto.
    rewrite dirlist_pred_except_delete; eauto.
    cancel.
    unfold BFILE.freepred,  BFILE.bfile0_owned; eauto.
    eauto.
    apply dirlist_safe_delete; auto.

    (* inum inside the new modified tree *)
    denote! (tree_dir_names_pred' _ _) as Hy.
    eapply find_dirlist_exists in Hy as Hy'.
    deex.
    denote dirlist_combine as Hx.
    eapply tree_inodes_distinct_delete in Hx as Hx'; eauto.
    eassumption.

    (* inum outside the original tree *)
    denote! (forall _ _, (_ = _ -> False) -> _ = _) as Hz.
    eapply Hz.
    intro; subst.
    denote! (In _ _ -> False) as Hq.
    eapply Hq.
    denote ((name |-> (_, false))%pred) as Hy.
    eapply find_dirlist_exists in Hy as Hy'; eauto.
    deex.
    eapply find_dirlist_tree_inodes; eauto.

    all: try solve[rewrite <- H1; cancel; eauto].
    
    unfold IAlloc.MSLog in *; cancel.
    step.

    cancel.

    (* case 2: is_dir: check empty *)
    prestep.
    intros; norm'l.
    denote dirlist_pred as Hx; subst_bool.
    rewrite dirlist_extract_subdir in Hx; eauto; simpl in Hx.
    unfold tree_dir_names_pred in Hx; destruct_lift Hx.
    cancel.
    eauto.

    step.
    step.
    step.
    Opaque corr2.
    prestep.
    intros mx Hmx.
    destruct_lift Hmx.
    exists F_, F; do 2 eexists;  exists mbase, sm, m.
    pred_apply; cancel.
    eauto.
    step.
    step.
    msalloc_eq.
    cancel.
    exists (list2nmem flist'). eexists.
    pred_apply. cancel.
    unfold IAlloc.MSLog in *.
    step.
    step.

    (* post conditions *)
    or_r; cancel.
    
    denote (pimpl _ freepred') as Hx; rewrite <- Hx.
    denote (tree_dir_names_pred' _ _) as Hz.
    erewrite (@dlist_is_nil _ _ _ _ _ Hz); eauto.
    rewrite dirlist_pred_except_delete; eauto.
    rewrite dir_names_delete with (dnum := dnum).
    cancel.

    eauto. eauto. eauto.
    reflexivity.
    destruct (Nat.eq_dec a0 dnum); subst.
    exfalso; eapply ptsto_conflict_F with (m:=list2nmem flist')(a:=dnum).
    pred_apply; cancel.
   
    apply dirlist_safe_delete; auto.

    (* inum inside the new modified tree *)
    eapply find_dirlist_exists in H14 as H14'.
    deex.
    denote dirlist_combine as Hx.
    eapply tree_inodes_distinct_delete in Hx as Hx'; eauto.
    eassumption.

    (* inum outside the original tree *)
    denote (selN _ _ _ = selN _ _ _) as Hs.
    denote (In _ (dirlist_combine _ _)) as Hi.
    denote (tree_dir_names_pred' tree_elem) as Ht.
    apply Hs.
    intro; subst.
    eapply Hi.
    eapply find_dirlist_exists with (inum := a0) in Ht as Ht'.
    deex.
    eapply find_dirlist_tree_inodes; eauto.
    eassumption.
    all: try solve [intros; rewrite <- H1; cancel; eauto].

    step.

    step.
    step.
    step.
    step.
    step.

    Unshelve.
    all: try match goal with | [ |- DirTreePred.SDIR.rep _ _ ] => eauto end.
    all: try exact unit.
    all: try solve [repeat constructor].
    all: eauto.
    all: try exact string_dec.
  Qed.


  Theorem read_ok :
    forall fsxp inum off mscs pr,
    {< F mbase sm m pathname Fm Ftop tree f Fd v ilist frees,
    PERM:pr   
    PRE:bm, hm, LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn mbase m) (MSLL mscs) sm bm hm *
           [[ (Fm * rep fsxp Ftop tree ilist frees mscs sm hm)%pred (list2nmem m) ]] *
           [[ find_subtree pathname tree = Some (TreeFile inum f) ]] *
           [[ (Fd * off |-> v)%pred (list2nmem (DFData f)) ]]
    POST:bm', hm', RET:^(mscs',r)
           LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn mbase m) (MSLL mscs') sm bm' hm' *
           [[ (Fm * rep fsxp Ftop tree ilist frees mscs' sm hm')%pred (list2nmem m) ]] *
           [[ bm' r = Some (fst v) /\ MSAlloc mscs' = MSAlloc mscs ]]
    CRASH:bm', hm',
           LOG.intact fsxp.(FSXPLog) F mbase sm bm' hm'
    >} read fsxp inum off mscs.
  Proof. 
    unfold read, rep.
    intros. prestep.
    intros m Hm; destruct_lift Hm.
    rewrite subtree_extract in * by eauto.
    cbn [tree_pred] in *. destruct_lifts.
    repeat eexists; pred_apply; norm.
    cancel.
    intuition.
    eassign (selN dummy13 inum BFILE.bfile0).
    erewrite <- list2nmem_sel; [|pred_apply; cancel].
    simpl.
    eapply list2nmem_inbound; eauto.
    msalloc_eq; pred_apply; cancel.
    apply list2nmem_ptsto_cancel.
    eapply list2nmem_inbound; eauto.
    pred_apply; cancel.
    erewrite <- list2nmem_sel; [|pred_apply; cancel].
    simpl; eauto.

    step.
    step; msalloc_eq.
    cancel.

    rewrite <- subtree_fold by eauto.
    pred_apply. cancel.

    rewrite <- H2; cancel; eauto.
  Qed.

  Theorem dwrite_ok :
    forall fsxp inum off h mscs pr,
    {< F ds sm pathname Fm Ftop tree f Fd v vs ilist frees,
    PERM:pr   
    PRE:bm, hm, LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn ds ds!!) (MSLL mscs) sm bm hm *
           [[[ ds!! ::: Fm * rep fsxp Ftop tree ilist frees mscs sm hm ]]] *
           [[ find_subtree pathname tree = Some (TreeFile inum f) ]] *
           [[[ (DFData f) ::: (Fd * off |-> vs) ]]] *
           [[ sync_invariant F ]] *
           [[ bm h = Some v ]] *
           [[ fst v = S inum ]]
    POST:bm', hm', RET:mscs'
           exists ds' tree' f' sm' bn,
           LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn ds' ds'!!) (MSLL mscs') sm' bm' hm' *
           [[ ds' = dsupd ds bn (v, vsmerge vs) ]] *
           [[ BFILE.block_belong_to_file ilist bn inum off ]] *
           [[ MSAlloc mscs' = MSAlloc mscs ]] *
           [[ MSCache mscs' = MSCache mscs ]] *
           [[ MSAllocC mscs' = MSAllocC mscs ]] *
           [[ MSIAllocC mscs' = MSIAllocC mscs ]] *
           (* spec about files on the latest diskset *)
           [[[ ds'!! ::: (Fm  * rep fsxp Ftop tree' ilist frees mscs' sm' hm') ]]] *
           [[ tree' = update_subtree pathname (TreeFile inum f') tree ]] *
           [[[ (DFData f') ::: (Fd * off |-> (v, vsmerge vs)) ]]] *
           [[ f' = mk_dirfile (updN (DFData f) off (v, vsmerge vs)) (DFAttr f) (DFOwner f) ]] *
           [[ dirtree_safe ilist (BFILE.pick_balloc frees (MSAlloc mscs')) tree
                           ilist (BFILE.pick_balloc frees (MSAlloc mscs')) tree' ]]
    XCRASH:bm', hm',
           LOG.recover_any fsxp.(FSXPLog) F ds sm bm' hm' \/
           exists bn sm', [[ BFILE.block_belong_to_file ilist bn inum off ]] *
           LOG.recover_any fsxp.(FSXPLog) F (dsupd ds bn (v, vsmerge vs)) sm' bm' hm'
    >} dwrite fsxp inum off h mscs.
  Proof. 
    unfold dwrite, rep.
    intros. prestep.
    intros m Hm; destruct_lift Hm.
    rewrite subtree_extract in * by eauto.
    cbn [tree_pred] in *. destruct_lifts.
    repeat eexists; pred_apply; norm.
    cancel.
    intuition.
    
    eassign ({| BFILE.BFData := DFData dummy7;
                BFILE.BFAttr := DFAttr dummy7;
                BFILE.BFOwner := DFOwner dummy7;
                BFILE.BFCache := dummy12 |}).
    simpl; eapply list2nmem_inbound; eauto.
    msalloc_eq; pred_apply; cancel.
    pred_apply; cancel.
    simpl; eauto.
    eauto.
    eauto.

    step.
    prestep.
    intros mx Hmx; destruct_lift Hmx.
    pred_apply; erewrite LOG.rep_hashmap_subset; eauto.
    msalloc_eq; cancel.
    rewrite <- subtree_absorb by eauto.
    cancel.
    simpl; eapply list2nmem_updN; eauto.

    eapply dirlist_safe_subtree; eauto.
    apply dirtree_safe_file.
    rewrite<- H2; cancel; eauto.
    xcrash.
    or_r; xcrash.
  Qed.

  Theorem datasync_ok :
    forall fsxp inum mscs pr,
    {< F ds sm pathname Fm Ftop tree f ilist frees,
    PERM:pr   
    PRE:bm, hm, LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn ds ds!!) (MSLL mscs) sm bm hm *
           [[[ ds!! ::: Fm * rep fsxp Ftop tree ilist frees mscs sm hm ]]] *
           [[ find_subtree pathname tree = Some (TreeFile inum f) ]] *
           [[ sync_invariant F ]]
    POST:bm', hm', RET:mscs'
           exists ds' sm' tree' al,
           LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn ds' ds'!!) (MSLL mscs') sm' bm' hm' *
           [[ tree' = update_subtree pathname (TreeFile inum (synced_dirfile f)) tree ]] *
           [[ ds' = dssync_vecs ds al ]] *
           [[[ ds'!! ::: (Fm * rep fsxp Ftop tree' ilist frees mscs' sm' hm') ]]] *
           [[ MSAlloc mscs' = MSAlloc mscs ]] *
           [[ MSCache mscs' = MSCache mscs ]] *
           [[ MSAllocC mscs' = MSAllocC mscs ]] *
           [[ MSIAllocC mscs' = MSIAllocC mscs ]] *
           [[ length al = length (DFData f) /\ forall i, i < length al ->
              BFILE.block_belong_to_file ilist (selN al i 0) inum i ]] *
           [[ dirtree_safe ilist (BFILE.pick_balloc frees (MSAlloc mscs')) tree
                           ilist (BFILE.pick_balloc frees (MSAlloc mscs')) tree' ]]
    CRASH:bm', hm',
           LOG.recover_any fsxp.(FSXPLog) F ds sm bm' hm'
    >} datasync fsxp inum mscs.
  Proof. 
    unfold datasync, rep.
    intros. prestep.
    intros m Hm; destruct_lift Hm.
    rewrite subtree_extract in * by eauto.
    cbn [tree_pred] in *. destruct_lifts.
    repeat eexists; pred_apply; norm.
    cancel.
    intuition.      
    pred_apply; cancel.
    pred_apply; cancel.

    step.
    step; msalloc_eq.
    cancel.
    rewrite <- subtree_absorb by eauto.
    pred_apply; cancel.
    eapply dirlist_safe_subtree; eauto.
    apply dirtree_safe_file.
  Qed.


  Theorem sync_ok :
    forall fsxp mscs pr,
    {< F ds sm Fm Ftop tree ilist frees,
    PERM:pr   
    PRE:bm, hm, LOG.rep fsxp.(FSXPLog) F (LOG.NoTxn ds) (MSLL mscs) sm bm hm *
           [[[ ds!! ::: Fm * rep fsxp Ftop tree ilist frees mscs sm hm ]]] *
           [[ sync_invariant F ]]
    POST:bm', hm', RET:mscs'
           LOG.rep fsxp.(FSXPLog) F (LOG.NoTxn (ds!!, nil)) (MSLL mscs') sm bm' hm' *
           [[ MSCache mscs' = MSCache mscs ]] *
           [[ MSAlloc mscs' = negb (MSAlloc mscs) ]] *
           [[ MSIAllocC mscs' = MSIAllocC mscs ]] *
           [[ MSAllocC mscs' = MSAllocC mscs ]] *
           [[ MSICache mscs' = MSICache mscs ]]
    XCRASH:bm', hm',
           LOG.recover_any fsxp.(FSXPLog) F ds sm bm' hm'
     >} sync fsxp mscs.
  Proof. 
    unfold sync, rep.
    hoare.
  Qed.

  
  Theorem sync_noop_ok :
    forall fsxp mscs pr,
    {< F ds sm Fm Ftop tree ilist frees,
    PERM:pr   
    PRE:bm, hm, LOG.rep fsxp.(FSXPLog) F (LOG.NoTxn ds) (MSLL mscs) sm bm hm *
           [[[ ds!! ::: Fm * rep fsxp Ftop tree ilist frees mscs sm hm ]]] *
           [[ sync_invariant F ]]
    POST:bm', hm', RET:mscs'
           LOG.rep fsxp.(FSXPLog) F (LOG.NoTxn ds) (MSLL mscs') sm bm' hm' *
           [[ MSCache mscs' = MSCache mscs ]] *
           [[ MSAlloc mscs' = negb (MSAlloc mscs) ]]
    XCRASH:bm', hm',
           LOG.recover_any fsxp.(FSXPLog) F ds sm bm' hm'
     >} sync_noop fsxp mscs.
  Proof. 
    unfold sync_noop, rep.
    hoare.
  Qed.

  Theorem truncate_ok :
    forall fsxp inum nblocks mscs pr,
    {< F ds sm d pathname Fm Ftop tree f frees ilist,
    PERM:pr   
    PRE:bm, hm, LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn ds d) (MSLL mscs) sm bm hm *
           [[[ d ::: Fm * rep fsxp Ftop tree ilist frees mscs sm hm ]]] *
           [[ find_subtree pathname tree = Some (TreeFile inum f) ]]
    POST:bm', hm', RET:^(mscs', ok)
           exists d',
           LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn ds d') (MSLL mscs') sm bm' hm' *
           [[ MSCache mscs' = MSCache mscs ]] *
           [[ MSAlloc mscs' = MSAlloc mscs ]] *
          ([[ isError ok ]] \/
           [[ ok = OK tt ]] *
           exists tree' f' ilist' frees',
           [[[ d' ::: Fm * rep fsxp Ftop tree' ilist' frees' mscs' sm hm' ]]] *
           [[ tree' = update_subtree pathname (TreeFile inum f') tree ]] *
           [[ f' = mk_dirfile (setlen (DFData f) nblocks valuset0) (DFAttr f) (DFOwner f) ]] *
           [[ dirtree_safe ilist  (BFILE.pick_balloc frees  (MSAlloc mscs')) tree
                           ilist' (BFILE.pick_balloc frees' (MSAlloc mscs')) tree' ]] *
           [[ nblocks >= Datatypes.length (DFData f) -> BFILE.treeseq_ilist_safe inum ilist ilist' ]])
    CRASH:bm', hm',
           LOG.intact fsxp.(FSXPLog) F ds sm bm' hm'
    >} truncate fsxp inum nblocks mscs.
  Proof. 
    unfold truncate, rep.
    intros. prestep.
    intros m Hm; destruct_lift Hm.
    assert (A: tree_names_distinct dummy7).
    eapply rep_tree_names_distinct with (m:= list2nmem dummy3).
    unfold rep; pred_apply; cancel.
    assert (A0: tree_inodes_distinct dummy7).
    eapply rep_tree_inodes_distinct with (m:= list2nmem dummy3).
    unfold rep; pred_apply; cancel.
    rewrite subtree_extract in * by eauto.
    cbn [tree_pred] in *. destruct_lifts.
    repeat eexists; pred_apply; norm.
    cancel.
    intuition.      
    pred_apply; cancel.
    pred_apply; cancel.
    eauto.

    step.
    step; msalloc_eq.

    step; msalloc_eq.
    intros mt Hmt; pose proof Hmt as Htemp; pred_apply.
    or_r; cancel.
    apply listmatch_emp.
    intros; cancel.
    rewrite <- subtree_absorb by eauto. cancel.
    eapply dirlist_safe_subtree; eauto.
    apply dirtree_safe_file_trans; auto.
  Qed.


  Theorem getlen_ok :
    forall fsxp inum mscs pr,
    {< F mbase sm m pathname Fm Ftop tree f frees ilist,
    PERM:pr   
    PRE:bm, hm, LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn mbase m) (MSLL mscs) sm bm hm *
           [[ (Fm * rep fsxp Ftop tree ilist frees mscs sm hm)%pred (list2nmem m) ]] *
           [[ find_subtree pathname tree = Some (TreeFile inum f) ]]
    POST:bm', hm', RET:^(mscs',r)
           LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn mbase m) (MSLL mscs') sm bm' hm' *
           [[ (Fm * rep fsxp Ftop tree ilist frees mscs' sm hm')%pred (list2nmem m) ]] *
           [[ r = length (DFData f) ]] *
           [[ MSCache mscs' = MSCache mscs ]] *
           [[ MSAlloc mscs' = MSAlloc mscs ]]
    CRASH:bm', hm',
           LOG.intact fsxp.(FSXPLog) F mbase sm bm' hm'
    >} getlen fsxp inum mscs.
  Proof. 
    unfold getlen, rep.
    intros. prestep.
    intros m Hm; destruct_lift Hm.
    rewrite subtree_extract in * by eauto.
    cbn [tree_pred] in *. destruct_lifts.
    repeat eexists; pred_apply; norm.
    cancel.
    intuition.      
    pred_apply; cancel.
    pred_apply; cancel.

    step.
    step; msalloc_eq.
    cancel.
    rewrite <- subtree_fold by eauto. pred_apply; cancel.
    rewrite<- H2; cancel; eauto.
  Qed.

  Theorem getattr_ok :
    forall fsxp inum mscs pr,
    {< F ds sm d pathname Fm Ftop tree f ilist frees,
    PERM:pr   
    PRE:bm, hm, LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn ds d) (MSLL mscs) sm bm hm *
           [[[ d ::: Fm * rep fsxp Ftop tree ilist frees mscs sm hm ]]] *
           [[ find_subtree pathname tree = Some (TreeFile inum f) ]]
    POST:bm', hm', RET:^(mscs',r)
           LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn ds d) (MSLL mscs') sm bm' hm' *
           [[[ d ::: Fm * rep fsxp Ftop tree ilist frees mscs' sm hm' ]]] *
           [[ MSCache mscs' = MSCache mscs ]] *
           [[ r = DFAttr f /\ MSAlloc mscs' = MSAlloc mscs ]]
    CRASH:bm', hm',
           LOG.intact fsxp.(FSXPLog) F ds sm bm' hm'
    >} getattr fsxp inum mscs.
  Proof.
    unfold getattr, rep.
    intros. prestep.
    intros m Hm; destruct_lift Hm.
    rewrite subtree_extract in * by eauto.
    cbn [tree_pred] in *. destruct_lifts.
    repeat eexists; pred_apply; norm.
    cancel.
    intuition.      
    pred_apply; cancel.
    pred_apply; cancel.

    step.
    step; msalloc_eq.
    cancel.
    rewrite <- subtree_fold by eauto. pred_apply; cancel.
    rewrite<- H2; cancel; eauto.
  Qed.

  
  Theorem setattr_ok :
    forall fsxp inum attr mscs pr,
    {< F mbase sm m pathname Fm Ftop tree f ilist frees,
    PERM:pr   
    PRE:bm, hm, LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn mbase m) (MSLL mscs) sm bm hm *
           [[ (Fm * rep fsxp Ftop tree ilist frees mscs sm hm)%pred (list2nmem m) ]] *
           [[ find_subtree pathname tree = Some (TreeFile inum f) ]] 
    POST:bm', hm', RET:mscs'
           exists m' tree' f' ilist',
           LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn mbase m') (MSLL mscs') sm bm' hm' *
           [[ (Fm * rep fsxp Ftop tree' ilist' frees mscs' sm hm')%pred (list2nmem m') ]] *
           [[ tree' = update_subtree pathname (TreeFile inum f') tree ]] *
           [[ f' = mk_dirfile (DFData f) attr (DFOwner f) ]] *
           [[ MSAlloc mscs' = MSAlloc mscs ]] *
           [[ dirtree_safe ilist  (BFILE.pick_balloc frees  (MSAlloc mscs')) tree
                           ilist' (BFILE.pick_balloc frees  (MSAlloc mscs')) tree' ]] *
           [[ BFILE.treeseq_ilist_safe inum ilist ilist' ]]
    CRASH:bm', hm',
           LOG.intact fsxp.(FSXPLog) F mbase sm bm' hm'
    >} setattr fsxp inum attr mscs.
  Proof.
    unfold setattr.
    intros. prestep.
    intros m Hm; destruct_lift Hm.
    assert (A: tree_names_distinct dummy7).
    eapply rep_tree_names_distinct with (m:= list2nmem dummy3).
    unfold rep; pred_apply; cancel.
    assert (A0: tree_inodes_distinct dummy7).
    eapply rep_tree_inodes_distinct with (m:= list2nmem dummy3).
    unfold rep; pred_apply; cancel.
    rewrite subtree_extract in * by eauto.
    cbn [tree_pred] in *. destruct_lifts.
    repeat eexists; pred_apply; norm.
    cancel.
    intuition.      
    pred_apply; cancel.
    pred_apply; cancel.

    step.
    step; msalloc_eq.
    cancel.
    rewrite <- subtree_absorb by eauto.
    pred_apply; cancel.
    eapply dirlist_safe_subtree; eauto.
    apply dirtree_safe_file_trans; auto.
  Qed.


  Hint Extern 1 ({{_|_}} Bind (read _ _ _ _) _) => apply read_ok : prog.
  Hint Extern 1 ({{_|_}} Bind (dwrite _ _ _ _ _) _) => apply dwrite_ok : prog.
  Hint Extern 1 ({{_|_}} Bind (datasync _ _ _) _) => apply datasync_ok : prog.
  Hint Extern 1 ({{_|_}} Bind (sync _ _) _) => apply sync_ok : prog.
  Hint Extern 1 ({{_|_}} Bind (sync_noop _ _) _) => apply sync_noop_ok : prog.
  Hint Extern 1 ({{_|_}} Bind (truncate _ _ _ _) _) => apply truncate_ok : prog.
  Hint Extern 1 ({{_|_}} Bind (getlen _ _ _) _) => apply getlen_ok : prog.
  Hint Extern 1 ({{_|_}} Bind (getattr _ _ _) _) => apply getattr_ok : prog.
  Hint Extern 1 ({{_|_}} Bind (getowner _ _ _) _) => apply getowner_ok : prog.
  Hint Extern 1 ({{W _|_ W}} Bind (getowner _ _ _) _) => apply getowner_ok_weak : prog.
  Hint Extern 1 ({{W _|_ W}} Bind (changeowner _ _ _ _) _) => apply changeowner_ok : prog.
  Hint Extern 1 ({{_|_}} Bind (setattr _ _ _ _) _) => apply setattr_ok : prog. 

 
  Theorem delete_ok :
    forall fsxp dnum name mscs pr,
    {< F mbase sm m pathname Fm Ftop tree tree_elem ilist frees,
    PERM:pr   
    PRE:bm, hm, LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn mbase m) (MSLL mscs) sm bm hm *
           [[ (Fm * rep fsxp Ftop tree ilist frees mscs sm hm)%pred (list2nmem m) ]] *
           [[ find_subtree pathname tree = Some (TreeDir dnum tree_elem) ]]
    POST:bm', hm', RET:^(mscs',r)
           exists m', LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn mbase m') (MSLL mscs') sm bm' hm' *
           [[ MSAlloc mscs' = MSAlloc mscs ]] *
           ([[ isError r ]] \/
            [[ r = OK tt ]] * exists tree' ilist' frees',
            [[ tree' = update_subtree pathname
                      (delete_from_dir name (TreeDir dnum tree_elem)) tree ]] *
            [[ (Fm * rep fsxp Ftop tree' ilist' frees' mscs' sm hm')%pred (list2nmem m') ]] *
            [[ dirtree_safe ilist  (BFILE.pick_balloc frees  (MSAlloc mscs')) tree
                            ilist' (BFILE.pick_balloc frees' (MSAlloc mscs')) tree' ]] *
            [[ forall inum def', inum <> dnum ->
                 (In inum (tree_inodes tree') \/ (~ In inum (tree_inodes tree))) ->
                selN ilist inum def' = selN ilist' inum def' ]])
    CRASH:bm', hm',
           LOG.intact fsxp.(FSXPLog) F mbase sm bm' hm'
    >} delete fsxp dnum name mscs.
  Proof. 
    intros; eapply pimpl_ok2. apply delete_ok'.

    intros; norml; unfold stars; simpl.
    rewrite rep_tree_distinct_impl in *.
    unfold rep in *; cancel.

    rewrite subtree_extract; eauto. simpl. instantiate (tree_elem0:=tree_elem). cancel.
    step.
    apply pimpl_or_r; right.
    intros mt Hmt; pred_apply.
    cancel.
    rewrite <- subtree_absorb; eauto.
    cancel.
    
    eapply dirlist_safe_subtree; eauto.
    denote (dirlist_combine tree_inodes _) as Hx.
    specialize (Hx inum def' H4).
    intuition; try congruence.

    destruct_lift H0.
    edestruct tree_inodes_pathname_exists. 3: eauto.
    eapply tree_names_distinct_update_subtree; eauto.
    eapply tree_names_distinct_delete_from_list.
    eapply tree_names_distinct_subtree; eauto.

    eapply tree_inodes_distinct_update_subtree; eauto.
    eapply tree_inodes_distinct_delete_from_list.
    eapply tree_inodes_distinct_subtree; eauto.
    simpl. eapply incl_cons2.
    eapply tree_inodes_incl_delete_from_list.

    (* case A: inum inside tree' *)

    repeat deex.
    destruct (pathname_decide_prefix pathname x); repeat deex.

    (* case 1: in the directory *)
    erewrite find_subtree_app in *; eauto.
    (* eapply H11. *)

    eapply find_subtree_inum_present in H17; simpl in *.
    intuition.

    (* case 2: outside the directory *)
    eapply H10.
    intro.
    edestruct tree_inodes_pathname_exists with (tree := TreeDir dnum tree_elem) (inum := dirtree_inum subtree).
    3: eassumption.

    eapply tree_names_distinct_subtree; eauto.
    eapply tree_inodes_distinct_subtree; eauto.

    destruct H21.
    destruct H21.

    eapply H6.
    exists x0.

    edestruct find_subtree_before_prune_general; eauto.

    eapply find_subtree_inode_pathname_unique.
    eauto. eauto.
    intuition eauto.
    erewrite find_subtree_app; eauto.
    intuition congruence.

    (* case B: outside original tree *)
    eapply H13; eauto.
    right.
    contradict H7; intuition eauto. exfalso; eauto.
    eapply tree_inodes_find_subtree_incl; eauto.
    simpl; intuition.
    
    Unshelve.
    all: eauto.
  Qed.

  Hint Extern 1 ({{_|_}} Bind (delete _ _ _ _) _) => apply delete_ok : prog.

  
  Theorem rename_cwd_ok :
    forall fsxp dnum srcpath srcname dstpath dstname mscs pr,
    {< F mbase m sm Fm Ftop tree tree_elem ilist frees,
    PERM:pr   
    PRE:bm, hm, LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn mbase m) (MSLL mscs) sm bm hm *
           [[ (Fm * rep fsxp Ftop tree ilist frees mscs sm hm)%pred (list2nmem m) ]] *
           [[ tree = TreeDir dnum tree_elem ]]
    POST:bm', hm', RET:^(mscs',r)
           exists m', LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn mbase m') (MSLL mscs') sm bm' hm' *
           [[ MSAlloc mscs' = MSAlloc mscs ]] *
           ([[ isError r ]] \/
            [[ r = OK tt ]] * exists snum sents dnum dents subtree pruned tree' ilist' frees',
            [[ find_subtree srcpath tree = Some (TreeDir snum sents) ]] *
            [[ find_dirlist srcname sents = Some subtree ]] *
            [[ pruned = tree_prune snum sents srcpath srcname tree ]] *
            [[ find_subtree dstpath pruned = Some (TreeDir dnum dents) ]] *
            [[ tree' = tree_graft dnum dents dstpath dstname subtree pruned ]] *
            [[ (Fm * rep fsxp Ftop tree' ilist' frees' mscs' sm hm')%pred (list2nmem m') ]] *
            [[ dirtree_safe ilist  (BFILE.pick_balloc frees  (MSAlloc mscs')) tree
                            ilist' (BFILE.pick_balloc frees' (MSAlloc mscs')) tree' ]] *
            [[ forall inum' def', inum' <> snum -> inum' <> dnum ->
               (In inum' (tree_inodes tree') \/ (~ In inum' (tree_inodes tree))) ->
               selN ilist inum' def' = selN ilist' inum' def' ]] )
    CRASH:bm', hm',
           LOG.intact fsxp.(FSXPLog) F mbase sm bm' hm'
    >} rename fsxp dnum srcpath srcname dstpath dstname mscs.
  Proof.
    unfold rename, rep.

    (* extract some basic facts *)
    prestep; norm'l.
    assert (tree_inodes_distinct (TreeDir dnum tree_elem)) as HnID.
    eapply rep_tree_inodes_distinct with (m := list2nmem m).
    pred_apply; unfold rep; cancel.
    assert (tree_names_distinct (TreeDir dnum tree_elem)) as HiID.
    eapply rep_tree_names_distinct with (m := list2nmem m).
    pred_apply; unfold rep; cancel.

    (* namei srcpath, isolate root tree file before cancel *)
    subst; simpl in *.
    denote tree_dir_names_pred as Hx; assert (Horig := Hx).
    unfold tree_dir_names_pred in Hx; destruct_lift Hx.
    cancel.

    (* BFILE.rep in post condition of namei doesn't unify with  BFILE.rep in context, 
       because namei may change cache content and promises a new BFILE.rep in its post
       condition, which we should use from now on. Should we clear the old BFILE.rep? *)
    denote! (_ (list2nmem m)) as Hm0; rewrite <- locked_eq in Hm0.

    instantiate (tree := TreeDir dnum tree_elem).
    unfold rep; simpl.
    unfold tree_dir_names_pred; cancel.
    all: eauto.

    (* lookup srcname, isolate src directory before cancel *)
    destruct_branch.
    destruct_branch; destruct_branch.

    prestep; norm'l.

    (* lock the old BFILE.rep again, but not the new one. *)
    denote! ( (Fm * BFILE.rep _ _ _ _ _ _ _ (MSCache mscs) _ _ * _)%pred (list2nmem m)) as Hm0; rewrite <- locked_eq in Hm0.

    intuition; inv_option_eq; repeat deex; destruct_pairs.
    denote find_name as Htree.
    apply eq_sym in Htree.
    apply find_name_exists in Htree.
    destruct Htree. intuition.

    denote find_subtree as Htree; assert (Hx := Htree).
    apply subtree_extract with (xp := fsxp) in Hx.
    denote tree_dir_names_pred as Hy; assert (Hsub := Hy).
    eapply pimpl_trans in Hsub; [ | | eapply pimpl_sep_star; [ apply pimpl_refl | apply Hx ] ];
      [ | cancel ]. clear Hx.
    destruct x; simpl in *; subst; try congruence.
    unfold tree_dir_names_pred in Hsub.
    destruct_lift Hsub.
    denote (_ |-> _)%pred as Hsub.
    inversion H4; subst.

    safecancel.

    (* unlink src *)
    destruct_branch.
    prestep.
    intros mx Hmx; destruct_lift Hmx; try congruence.
    repeat eexists; pred_apply; norm; try congruence.
    cancel.
    intuition.
    eauto.    

    (* lock an old BFILE.rep *)
    denote! ( ((Fm * BFILE.rep _ _ _ _ _ _ _ (MSCache a) _ _ ) * _)%pred (list2nmem m)) as Hm1; rewrite <- locked_eq in Hm1.

    (* namei for dstpath, find out pruning subtree before step *)
    eauto.
    eauto.
    eauto.

    denote (tree_dir_names_pred' l0 _) as Hx1.
    denote (_ |-> (_, _))%pred as Hx2.
    pose proof (ptsto_subtree_exists _ Hx1 Hx2) as Hx.
    destruct Hx; intuition.
    step; msalloc_eq.
    cancel.
    {
      cancel.
      match goal with |- context [(?inum_ |-> _)%pred] =>
        eapply pimpl_trans; [ eapply pimpl_trans; [ |
        eapply subtree_prune_absorb with (inum := inum_) (ri := dnum) (re := tree_elem) (xp := fsxp) (path := srcpath)
        ] | ]
      end.
      all: eauto using dir_names_pred_delete'.
      cancel.                               
    }

    rewrite tree_prune_preserve_inum; eauto.
    rewrite tree_prune_preserve_isdir; auto.

    (* fold back predicate for the pruned tree in hypothesis as well  *)
    denote (list2nmem flist) as Hinterm.
    assert (A: (((dirlist_pred (tree_pred fsxp) l0
                ✶ tree_pred_except fsxp srcpath (TreeDir dnum tree_elem))
               ✶ Ftop) ✶ dummy6) =p=> ((dirlist_pred (tree_pred fsxp) l0
                ✶ tree_pred_except fsxp srcpath (TreeDir dnum tree_elem))
                                        ✶ (Ftop ✶ dummy6))).
    cancel.
    rewrite A in Hinterm.
    eapply subtree_prune_absorb in Hinterm; eauto.
    2: apply dir_names_pred_delete'; auto.
    rename x into mvtree.

    (* lookup dstname *)
    destruct_branch.
    destruct_branch; destruct_branch.

    (* lock an old BFILE.rep; we have a new one from namei *)
    denote! ( (_* BFILE.rep _ _ _ _ _ _ _ (MSCache a0) _ _ )%pred (list2nmem m)) as Hm2; rewrite <- locked_eq in Hm2.

    prestep; norm'l.
    intuition; inv_option_eq; repeat deex; destruct_pairs.

    denote find_name as Hpruned.
    apply eq_sym in Hpruned.
    apply find_name_exists in Hpruned.
    destruct Hpruned. intuition.

    denote (list2nmem dummy11) as Hinterm1.
    denote find_subtree as Hpruned; assert (Hx := Hpruned).
    apply subtree_extract with (xp := fsxp) in Hx.
    assert (Hdst := Hinterm1); rewrite Hx in Hdst; clear Hx.
    destruct x; simpl in *; subst; try congruence; inv_option_eq.
    unfold tree_dir_names_pred in Hdst.
    destruct_lift Hdst.

    safecancel.
    eauto.

    denote! ( ((_ * Fm) * BFILE.rep _ _ _ _ _ _ _ (MSCache a4) _ _ )%pred (list2nmem m')) as Hm3; rewrite <- locked_eq in Hm3.

    (* grafting back *)
    destruct_branch.

    (* case 1: dst exists, try delete *)
    prestep.
    norml; msalloc_eq.
    unfold stars; simpl; inv_option_eq.
    denote (tree_dir_names_pred' _ _) as Hx3.
    denote (_ |-> (_, _))%pred as Hx4.
    pose proof (ptsto_subtree_exists _ Hx3 Hx4) as Hx.
    destruct Hx; intuition.

    denote! ( ((Fm * BFILE.rep _ _ _ _ _ _ (MSAllocC a1) _ _ _) * _)%pred (list2nmem m')) as Hm4; rewrite <- locked_eq in Hm4.

    (* must unify [find_subtree] in [delete]'s precondition with
       the root tree node.  have to do this manually *)
    unfold rep; norm. cancel. intuition.
    pred_apply; norm. cancel. intuition.
    eassign (tree_prune v_1 l0 srcpath srcname (TreeDir dnum tree_elem)).
    (* it would have been nice if we could have used Hinterm, as the old
       proof did, but flist has changed because of caching, and we need to
       use the latest flist and fold things back together again. *)
    2: eauto.
    pred_apply.
    cancel.
    rewrite helper_reorder_sep_star_3.
    rewrite fold_back_dir_pred; eauto.
    rewrite helper_reorder_sep_star_4.
    rewrite subtree_fold; eauto. 
    cancel.

    (* now, get ready for link *)
    destruct_branch.
    prestep; norml; inv_option_eq; msalloc_eq.
    denote mvtree as Hx. assert (Hdel := Hx).
    setoid_rewrite subtree_extract in Hx at 2.
    2: subst; eapply find_update_subtree; eauto.
    simpl in Hx; unfold tree_dir_names_pred in Hx; destruct_lift Hx.

    denote! ( _ (list2nmem m')) as Hm5; rewrite <- locked_eq in Hm5.
    intros my Hmy.
    repeat eexists; pred_apply; norm.
    cancel.
    intuition.
    pred_apply; cancel.
    pred_apply; cancel.
    eauto.
    eapply tree_pred_ino_goodSize; eauto.

    pred_apply' Hdel; cancel.

    step.
    safestep; msalloc_eq.
    or_l; cancel.
    safestep; msalloc_eq.
    or_r; cancel; eauto.
    simpl.
    erewrite subtree_graft_absorb_delete; eauto.
    msalloc_eq.
    eapply dirtree_safe_rename_dest_exists; eauto.

    (* case 1: in the new tree *)
    denote BFILE.treeseq_ilist_safe as Hsafe.
    unfold BFILE.treeseq_ilist_safe in Hsafe; destruct Hsafe as [Hsafe0 Hsafe1].
    rewrite <- Hsafe1 by auto.

    denote (selN ilist _ _ = selN ilist' _ _) as Hi.
    eapply Hi; eauto.

    eapply prune_graft_preserves_inodes; eauto.

    (* case 2: out of the original tree *)
    denote BFILE.treeseq_ilist_safe as Hsafe.
    unfold BFILE.treeseq_ilist_safe in Hsafe; destruct Hsafe as [Hsafe0 Hsafe1].
    rewrite <- Hsafe1 by auto.

    denote (selN ilist _ _ = selN ilist' _ _) as Hi.
    eapply Hi; eauto.
    right. intros HH.
    eapply tree_inodes_incl_delete_from_dir in HH; eauto.
    unfold tree_prune in *.
    cbn in *; intuition.

    all: try solve [intros; rewrite <- H1; cancel; eauto].

    safestep.
    safestep.
    or_l; cancel.
    cancel.

    (* dst is None *)   
    prestep.
    intros my Hmy; destruct_lift Hmy; try congruence.
    repeat eexists; pred_apply; norm; try congruence.
    cancel.
    intuition.
    msalloc_eq; pred_apply; cancel.
    eauto.
    eauto.
    eapply tree_pred_ino_goodSize; eauto.
    denote (_ (list2nmem dummy17)) as H'.
    pred_apply' H'; cancel.   (* Hinterm as above *)

    step.
    safestep; msalloc_eq.
    or_l; cancel.

    safestep; msalloc_eq.
    or_r; cancel; eauto.

    erewrite subtree_graft_absorb; eauto.
    msalloc_eq.
    eapply dirtree_safe_rename_dest_none; eauto.
    eapply notindomain_not_in_dirents; eauto.

    denote BFILE.treeseq_ilist_safe as Hsafe.
    unfold BFILE.treeseq_ilist_safe in Hsafe; destruct Hsafe as [Hsafe0 Hsafe1].
    apply Hsafe1; auto.

    denote BFILE.treeseq_ilist_safe as Hsafe.
    unfold BFILE.treeseq_ilist_safe in Hsafe; destruct Hsafe as [Hsafe0 Hsafe1].
    apply Hsafe1; auto.

    rewrite <- H1; cancel; eauto.

    step.
    step.

    step.
    step.

    step.
    step.

    step.
    step.

    step.
    step.

    Unshelve.
    all: try exact unit.
    all: try solve [repeat econstructor].
    all: try eauto.
    all: cbv [Mem.EqDec]; decide equality.
  Qed.

  Theorem rename_ok :
    forall fsxp dnum srcpath srcname dstpath dstname mscs pr,
    {< F mbase sm m pathname Fm Ftop tree tree_elem ilist frees,
    PERM:pr   
    PRE:bm, hm, LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn mbase m) (MSLL mscs) sm bm hm *
           [[ (Fm * rep fsxp Ftop tree ilist frees mscs sm hm)%pred (list2nmem m) ]] *
           [[ find_subtree pathname tree = Some (TreeDir dnum tree_elem) ]]
    POST:bm', hm', RET:^(mscs',r)
           exists m', LOG.rep fsxp.(FSXPLog) F (LOG.ActiveTxn mbase m') (MSLL mscs') sm bm' hm' *
           [[ MSAlloc mscs' = MSAlloc mscs ]] *
           ([[ isError r ]] \/
            [[ r = OK tt ]] *
            exists srcnum srcents dstnum dstents subtree pruned renamed tree' ilist' frees',
            [[ find_subtree srcpath (TreeDir dnum tree_elem) = Some (TreeDir srcnum srcents) ]] *
            [[ find_dirlist srcname srcents = Some subtree ]] *
            [[ pruned = tree_prune srcnum srcents srcpath srcname (TreeDir dnum tree_elem) ]] *
            [[ find_subtree dstpath pruned = Some (TreeDir dstnum dstents) ]] *
            [[ renamed = tree_graft dstnum dstents dstpath dstname subtree pruned ]] *
            [[ tree' = update_subtree pathname renamed tree ]] *
            [[ (Fm * rep fsxp Ftop tree' ilist' frees' mscs' sm hm')%pred (list2nmem m') ]] *
            [[ dirtree_safe ilist  (BFILE.pick_balloc frees  (MSAlloc mscs')) tree
                            ilist' (BFILE.pick_balloc frees' (MSAlloc mscs')) tree' ]] *
            [[ forall inum' def', inum' <> srcnum -> inum' <> dstnum ->
               In inum' (tree_inodes tree') ->
               selN ilist inum' def' = selN ilist' inum' def' ]] )
    CRASH:bm', hm',
           LOG.intact fsxp.(FSXPLog) F mbase sm bm' hm'
    >} rename fsxp dnum srcpath srcname dstpath dstname mscs.
  Proof.
    intros; eapply pimpl_ok2. apply rename_cwd_ok.

    intros; norml; unfold stars; simpl.
    rewrite rep_tree_distinct_impl in *.
    unfold rep in *; cancel.
    rewrite subtree_extract; eauto. simpl. instantiate (tree_elem0:=tree_elem).
    cancel.
    step.
    apply pimpl_or_r; right. cancel; eauto.
    rewrite <- subtree_absorb; eauto.
    cancel.
    rewrite tree_graft_preserve_inum; auto.
    rewrite tree_prune_preserve_inum; auto.
    rewrite tree_graft_preserve_isdir; auto.
    rewrite tree_prune_preserve_isdir; auto.
    eapply dirlist_safe_subtree; eauto.

    denote! (((Fm * BFILE.rep _ _ _ _ _ _ _ _ _ _) * IAlloc.rep _ _ _ _ _)%pred _) as Hm'.
    eapply pimpl_apply in Hm'.
    eapply rep_tree_names_distinct in Hm' as Hnames.
    eapply rep_tree_inodes_distinct in Hm' as Hinodes.
    2: unfold rep; cancel.
    2: rewrite <- subtree_absorb.
    2: cancel.
    
    2: eassign tree;
       eassign (tree_graft dnum0 dents dstpath dstname subtree
               (tree_prune snum sents srcpath srcname (TreeDir dnum tree_elem)));
       eassign pathname.
    2: cancel.
    2: eauto.
    2: rewrite tree_graft_preserve_inum; auto.
    2: rewrite tree_prune_preserve_inum; auto.
    2: rewrite tree_graft_preserve_isdir; auto.
    2: rewrite tree_prune_preserve_isdir; auto.

    edestruct tree_inodes_pathname_exists. 3: eauto. all: eauto.
    repeat deex.
    destruct (pathname_decide_prefix pathname x); repeat deex.

    (* case 1: inum inside tree' *)
    erewrite find_subtree_app in *; eauto.

    (* case 2: inum outside tree' *)
    denote (selN ilist _ _ = selN ilist' _ _) as Hilisteq.
    eapply Hilisteq; eauto.
    right. intros.

    denote ([[ tree_names_distinct _ ]]%pred) as Hlift. destruct_lift Hlift.
    edestruct find_subtree_update_subtree_oob_general; eauto.
    edestruct tree_inodes_pathname_exists with (tree := TreeDir dnum tree_elem) (inum := dirtree_inum subtree0) as [pn_conflict ?].
    eapply tree_names_distinct_subtree; [ | eauto ]; eauto.
    eapply tree_inodes_distinct_subtree; [ | | eauto ]; eauto.
    simpl; intuition.

    denote! (exists _, find_subtree _ _ = _ /\ dirtree_inum _ = dirtree_inum _) as Hx.
    destruct Hx.

    denote! (~ (exists _, _ = _ ++ _)) as Hsuffix.
    eapply Hsuffix.
    exists pn_conflict.

    eapply find_subtree_inode_pathname_unique with (tree := tree).
    eauto. eauto.

    intuition eauto.
    erewrite find_subtree_app by eauto; intuition eauto.
    intuition congruence.

    Unshelve.
    all: try exact unit.
    all: intros; eauto using BFILE.MSIAlloc.
    all: try solve [do 5 econstructor].
    all: try (cbv [Mem.EqDec]; decide equality).
    all: try exact emp.
    all: intros; try exact True.
  Qed.

  Hint Extern 1 ({{_|_}} Bind (rename _ _ _ _ _ _ _) _) => apply rename_ok : prog.

End DIRTREE.
