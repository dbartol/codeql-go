/**
 * Provides classes for working with static single assignment form (SSA).
 */

import go
private import SsaImpl

/**
 * A variable that can be SSA converted, that is, a local variable, but not a variable
 * declared in file scope.
 */
class SsaSourceVariable extends LocalVariable {
  SsaSourceVariable() {
    not getScope() instanceof FileScope
  }

  /**
   * Holds if there may be indirect references of this variable that are not covered by `getAReference()`.
   *
   * This is the case for variables that have their address taken, and for variables whose
   * name resolution information may be incomplete (for instance due to an extractor error).
   */
  predicate mayHaveIndirectReferences() {
    // variables that have their address taken
    exists(AddressExpr addr | addr.getOperand().stripParens() = getAUse())
    or
    exists(DataFlow::MethodReadNode mrn |
      mrn.getReceiver() = getARead() and
      mrn.getMethod().getReceiverType() instanceof PointerType
    )
    or
    // variables where there is an unresolved reference with the same name in the same
    // scope or a nested scope, suggesting that name resolution information may be incomplete
    exists(FunctionScope scope, FuncDef inner |
      scope = this.getScope().(LocalScope).getEnclosingFunctionScope() and
      unresolvedReference(getName(), inner) and
      inner.getScope().getOuterScope*() = scope
    )
  }
}

/**
 * Holds if there is an unresolved reference to `name` in `fn`.
 */
private predicate unresolvedReference(string name, FuncDef fn) {
  exists(Ident unresolved |
    unresolved.getName() = name and
    unresolved instanceof ReferenceExpr and
    not unresolved = any(SelectorExpr sel).getSelector() and
    not unresolved.refersTo(_) and
    fn = unresolved.getEnclosingFunction()
  )
}

/**
 * An SSA variable.
 */
class SsaVariable extends TSsaDefinition {
  /** Gets the source variable corresponding to this SSA variable. */
  SsaSourceVariable getSourceVariable() { result = this.(SsaDefinition).getSourceVariable() }

  /** Gets the (unique) definition of this SSA variable. */
  SsaDefinition getDefinition() { result = this }

  /** Gets the type of this SSA variable. */
  Type getType() { result = getSourceVariable().getType() }

  /** Gets a use in basic block `bb` that refers to this SSA variable. */
  IR::Instruction getAUseIn(ReachableBasicBlock bb) {
    exists(int i, SsaSourceVariable v | v = getSourceVariable() |
      result = bb.getNode(i) and
      this = getDefinition(bb, i, v)
    )
  }

  /** Gets a use that refers to this SSA variable. */
  IR::Instruction getAUse() { result = getAUseIn(_) }

  /** Gets a textual representation of this element. */
  string toString() { result = getDefinition().prettyPrintRef() }

  /**
   * Holds if this element is at the specified location.
   * The location spans column `startcolumn` of line `startline` to
   * column `endcolumn` of line `endline` in file `filepath`.
   * For more information, see
   * [Locations](https://help.semmle.com/QL/learn-ql/ql/locations.html).
   */
  predicate hasLocationInfo(
    string filepath, int startline, int startcolumn, int endline, int endcolumn
  ) {
    getDefinition().hasLocationInfo(filepath, startline, startcolumn, endline, endcolumn)
  }
}

/**
 * An SSA definition.
 */
class SsaDefinition extends TSsaDefinition {
  /** Gets the SSA variable defined by this definition. */
  SsaVariable getVariable() { result = this }

  /** Gets the source variable defined by this definition. */
  abstract SsaSourceVariable getSourceVariable();

  /**
   * Gets the basic block to which this definition belongs.
   */
  abstract ReachableBasicBlock getBasicBlock();

  /**
   * INTERNAL: Use `getBasicBlock()` and `getSourceVariable()` instead.
   *
   * Holds if this is a definition of source variable `v` at index `idx` in basic block `bb`.
   *
   * Phi nodes are considered to be at index `-1`, all other definitions at the index of
   * the control flow node they correspond to.
   */
  abstract predicate definesAt(ReachableBasicBlock bb, int idx, SsaSourceVariable v);

  /**
   * INTERNAL: Use `toString()` instead.
   *
   * Gets a pretty-printed representation of this SSA definition.
   */
  abstract string prettyPrintDef();

  /**
   * INTERNAL: Do not use.
   *
   * Gets a pretty-printed representation of a reference to this SSA definition.
   */
  abstract string prettyPrintRef();

  /** Gets the innermost function or file to which this SSA definition belongs. */
  ControlFlow::Root getRoot() { result = getBasicBlock().getRoot() }

  /** Gets a textual representation of this element. */
  string toString() { result = prettyPrintDef() }

  /**
   * Holds if this element is at the specified location.
   * The location spans column `startcolumn` of line `startline` to
   * column `endcolumn` of line `endline` in file `filepath`.
   * For more information, see
   * [Locations](https://help.semmle.com/QL/learn-ql/ql/locations.html).
   */
  abstract predicate hasLocationInfo(
    string filepath, int startline, int startcolumn, int endline, int endcolumn
  );
}

/**
 * An SSA definition that corresponds to an explicit assignment or other variable definition.
 */
class SsaExplicitDefinition extends SsaDefinition, TExplicitDef {
  IR::Instruction getInstruction() {
    exists(BasicBlock bb, int i | this = TExplicitDef(bb, i, _) | result = bb.getNode(i))
  }

  IR::Instruction getRhs() { getInstruction().writes(_, result) }

  override predicate definesAt(ReachableBasicBlock bb, int i, SsaSourceVariable v) {
    this = TExplicitDef(bb, i, v)
  }

  override ReachableBasicBlock getBasicBlock() { definesAt(result, _, _) }

  override SsaSourceVariable getSourceVariable() { this = TExplicitDef(_, _, result) }

  override string prettyPrintRef() {
    exists(int l, int c | hasLocationInfo(_, l, c, _, _) | result = "def@" + l + ":" + c)
  }

  override string prettyPrintDef() { result = "definition of " + getSourceVariable() }

  override predicate hasLocationInfo(
    string filepath, int startline, int startcolumn, int endline, int endcolumn
  ) {
    getInstruction().hasLocationInfo(filepath, startline, startcolumn, endline, endcolumn)
  }
}

module SsaExplicitDefinition {
  /**
   * Gets the SSA definition corresponding to definition `def`.
   */
  SsaExplicitDefinition of(IR::Instruction def) { result.getInstruction() = def }
}

/**
 * An SSA definition that does not correspond to an explicit variable definition.
 */
abstract class SsaImplicitDefinition extends SsaDefinition {
  /**
   * INTERNAL: Do not use.
   *
   * Gets the definition kind to include in `prettyPrintRef`.
   */
  abstract string getKind();

  override string prettyPrintRef() {
    exists(int l, int c | hasLocationInfo(_, l, c, _, _) | result = getKind() + "@" + l + ":" + c)
  }

  override predicate hasLocationInfo(
    string filepath, int startline, int startcolumn, int endline, int endcolumn
  ) {
    endline = startline and
    endcolumn = startcolumn and
    getBasicBlock().hasLocationInfo(filepath, startline, startcolumn, _, _)
  }
}

/**
 * An SSA definition representing the capturing of an SSA-convertible variable
 * in the closure of a nested function.
 *
 * Capturing definitions appear at the beginning of such functions, as well as
 * at any function call that may affect the value of the variable.
 */
class SsaVariableCapture extends SsaImplicitDefinition, TCapture {
  override predicate definesAt(ReachableBasicBlock bb, int i, SsaSourceVariable v) {
    this = TCapture(bb, i, v)
  }

  override ReachableBasicBlock getBasicBlock() { definesAt(result, _, _) }

  override SsaSourceVariable getSourceVariable() { definesAt(_, _, result) }

  override string getKind() { result = "capture" }

  override string prettyPrintDef() { result = "capture variable " + getSourceVariable() }

  override predicate hasLocationInfo(
    string filepath, int startline, int startcolumn, int endline, int endcolumn
  ) {
    exists(ReachableBasicBlock bb, int i | definesAt(bb, i, _) |
      bb.getNode(i).hasLocationInfo(filepath, startline, startcolumn, endline, endcolumn)
    )
  }
}

/**
 * An SSA definition such as a phi node that has no actual semantics, but simply serves to
 * merge or filter data flow.
 */
abstract class SsaPseudoDefinition extends SsaImplicitDefinition {
  /**
   * Gets an input of this pseudo-definition.
   */
  abstract SsaVariable getAnInput();

  /**
   * Gets a textual representation of the inputs of this pseudo-definition
   * in lexicographical order.
   */
  string ppInputs() { result = concat(getAnInput().getDefinition().prettyPrintRef(), ", ") }
}

/**
 * An SSA phi node, that is, a pseudo-definition for a variable at a point
 * in the flow graph where otherwise two or more definitions for the variable
 * would be visible.
 */
class SsaPhiNode extends SsaPseudoDefinition, TPhi {
  override SsaVariable getAnInput() {
    result = getDefReachingEndOf(getBasicBlock().getAPredecessor(), getSourceVariable())
  }

  override predicate definesAt(ReachableBasicBlock bb, int i, SsaSourceVariable v) {
    bb = getBasicBlock() and v = getSourceVariable() and i = -1
  }

  override ReachableBasicBlock getBasicBlock() { this = TPhi(result, _) }

  override SsaSourceVariable getSourceVariable() { this = TPhi(_, result) }

  override string getKind() { result = "phi" }

  override string prettyPrintDef() { result = getSourceVariable() + " = phi(" + ppInputs() + ")" }

  override predicate hasLocationInfo(
    string filepath, int startline, int startcolumn, int endline, int endcolumn
  ) {
    endline = startline and
    endcolumn = startcolumn and
    getBasicBlock().hasLocationInfo(filepath, startline, startcolumn, _, _)
  }
}

/**
 * An SSA variable, possibly with a chain of field reads on it.
 */
private newtype TSsaWithFields =
  TRoot(SsaVariable v) or
  TStep(SsaWithFields base, Field f) { exists(accessPathAux(base, f)) }

/**
 * Gets a representation of `nd` as an ssa-with-fields value if there is one.
 */
private TSsaWithFields accessPath(IR::Instruction insn) {
  exists(SsaVariable v | insn = v.getAUse() | result = TRoot(v))
  or
  exists(SsaWithFields base, Field f | insn = accessPathAux(base, f) | result = TStep(base, f))
}

/**
 * Gets a data-flow node that reads a field `f` from a node that is represented
 * by ssa-with-fields value `base`.
 */
private IR::Instruction accessPathAux(TSsaWithFields base, Field f) {
  exists(IR::FieldReadInstruction fr | fr = result |
    base = accessPath(fr.getBase()) and
    f = fr.getField()
  )
}

class SsaWithFields extends TSsaWithFields {
  /**
   * Gets the SSA variable corresponding to the base of this SSA variable with fields.
   *
   * For example, the SSA variable corresponding to `a` for the SSA variable with fields
   * corresponding to `a.b`.
   */
  SsaVariable getBaseVariable() {
    this = TRoot(result)
    or
    exists(SsaWithFields base, Field f | this = TStep(base, f) | result = base.getBaseVariable())
  }

  /** Gets a use that refers to this SSA variable with fields. */
  DataFlow::Node getAUse() { this = accessPath(result.asInstruction()) }

  /** Gets a textual representation of this element. */
  string toString() {
    exists(SsaVariable var | this = TRoot(var) | result = "(" + var + ")")
    or
    exists(SsaWithFields base, Field f | this = TStep(base, f) | result = base + "." + f.getName())
  }

  /**
   * Holds if this element is at the specified location.
   * The location spans column `startcolumn` of line `startline` to
   * column `endcolumn` of line `endline` in file `filepath`.
   * For more information, see
   * [Locations](https://help.semmle.com/QL/learn-ql/ql/locations.html).
   */
  predicate hasLocationInfo(
    string filepath, int startline, int startcolumn, int endline, int endcolumn
  ) {
    this.getBaseVariable().hasLocationInfo(filepath, startline, startcolumn, endline, endcolumn)
  }
}
