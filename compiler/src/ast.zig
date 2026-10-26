//! AST for the surface grammar in `../../grammar.ebnf`.
//!
//! All nodes are arena-allocated by the parser.  Lexemes and names are slices
//! into the original source text, so the source must outlive the AST.

const std = @import("std");

pub const Span = struct {
    offset: usize = 0,
    line: usize = 1,
    column: usize = 1,
};

pub const SpanMap = std.AutoHashMapUnmanaged(usize, Span);

pub const Module = struct {
    items: []*Item,
    /// Item/statement-level source spans keyed by AST pointer.  Expression
    /// diagnostics use the nearest enclosing statement span.
    spans: SpanMap = .empty,
};

pub const Item = struct {
    attributes: []Attribute,
    visibility: ?Visibility,
    kind: ItemKind,
};

pub const ItemKind = union(enum) {
    use: UseDecl,
    mod: ModDecl,
    struct_decl: StructDecl,
    enum_decl: EnumDecl,
    table_decl: TableDecl,
    trigger_decl: TriggerDecl,
    plugin_decl: PluginDecl,
    function: FunctionDecl,
    sys: SysDecl,
    impl: ImplDecl,
    trait_decl: TraitDecl,
    binding: Binding,
    uninitialized: UninitializedDecl,
};

pub const Visibility = struct {
    scope: ?VisibilityScope,
};

pub const VisibilityScope = union(enum) {
    crate,
    self,
    super,
    in_path: Path,
};

pub const Attribute = struct {
    path: Path,
    args: []*Expr,
};

pub const GenericParam = struct {
    name: []const u8,
    bounds: []*Type,
};

pub const WherePredicate = struct {
    ty: *Type,
    bounds: []*Type,
};

pub const WhereClause = struct {
    predicates: []WherePredicate,
};

pub const Path = struct {
    segments: []PathSegment,
};

pub const PathSegment = struct {
    name: []const u8,
    args: []*Type,
};

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub const Type = union(enum) {
    /// `!T`
    inferred_error: *Type,
    /// `E!T`
    error_union: ErrorUnion,
    /// `?T`
    optional: *Type,
    /// `&T` / `&mut T`
    reference: Reference,
    /// `*T`
    box: *Type,
    /// `*raw T`
    raw_pointer: *Type,
    /// `(A, B) -> T`
    function: FunctionType,
    /// `(A, B)`, `(A,)`, `()`, `(A)`
    tuple: []*Type,
    /// `[T]` / `[T; N]` / `[T; N, M]`
    array: ArrayType,
    /// `map[K, V]`
    map: MapType,
    /// `nil` in type position: the unit/empty result type.
    nil_type,
    /// `Foo<T>::Bar`
    path: Path,
};

pub const ErrorUnion = struct {
    error_type: *Type,
    value_type: *Type,
};

pub const Reference = struct {
    mutable: bool,
    child: *Type,
};

pub const FunctionType = struct {
    params: []*Type,
    result: *Type,
};

pub const ArrayType = struct {
    element: *Type,
    length: ?*Expr,
    columns: ?*Expr = null,
};

pub const MapType = struct {
    key: *Type,
    value: *Type,
};

// ---------------------------------------------------------------------------
// Items
// ---------------------------------------------------------------------------

pub const UseDecl = struct {
    tree: UseTree,
};

pub const UseTree = union(enum) {
    path: UsePath,
    glob: Path,
    group: UseGroup,
};

pub const UsePath = struct {
    path: Path,
    alias: ?[]const u8,
};

pub const UseGroup = struct {
    prefix: Path,
    trees: []UseTree,
};

pub const ModDecl = struct {
    name: []const u8,
    /// `null` for an external module reference.  External modules may be
    /// terminated by `;` (`mod foo;`) or by a newline/EOF (`mod foo`).
    items: ?[]*Item,
};

pub const Field = struct {
    attributes: []Attribute,
    visibility: ?Visibility,
    name: []const u8,
    ty: *Type,
};

pub const StructDecl = struct {
    name: []const u8,
    generics: []GenericParam,
    where_clause: ?WhereClause,
    fields: []Field,
};

pub const TableDecl = struct {
    name: []const u8,
    generics: []GenericParam,
    where_clause: ?WhereClause,
    fields: []Field,
    has_ellipsis: bool,
};

pub const TriggerDecl = struct {
    name: []const u8,
    generics: []GenericParam,
    where_clause: ?WhereClause,
    fields: []Field,
};

/// `Name <- plugin` with an optional body of member declarations (typically
/// `init <- sys (...)`).  Members are collected in the plugin's own scope; the
/// plugin itself is a world-registration descriptor whose execution is owned by
/// a later ECS task.
pub const PluginDecl = struct {
    name: []const u8,
    generics: []GenericParam,
    where_clause: ?WhereClause,
    items: []*Item,
};

pub const EnumDecl = struct {
    name: []const u8,
    generics: []GenericParam,
    where_clause: ?WhereClause,
    variants: []Variant,
};

pub const Variant = struct {
    name: []const u8,
    payload: VariantPayload,
};

pub const VariantPayload = union(enum) {
    unit,
    tuple: []Payload,
    struct_fields: []Field,
};

pub const Payload = struct {
    /// `null` for `Variant(T)`; named for `Variant(f: T)`.
    name: ?[]const u8,
    ty: *Type,
};

pub const Param = struct {
    name: []const u8,
    ty: *Type,
};

pub const FunctionDecl = struct {
    name: []const u8,
    is_async: bool = false,
    generics: []GenericParam,
    params: []Param,
    result: *Type,
    where_clause: ?WhereClause,
    body: FunctionBody,
};

pub const FunctionBody = union(enum) {
    expr: *Expr,
    block: *Block,
};

pub const FunctionExpr = struct {
    is_async: bool = false,
    params: []Param,
    result: *Type,
    body: FunctionBody,
};

pub const SysDecl = struct {
    name: []const u8,
    generics: []GenericParam,
    params: []SysParam,
    where_clause: ?WhereClause,
    body: *Block,
};

pub const SysParam = union(enum) {
    normal: Param,
    query: QueryParam,
    resource: Param,
};

pub const QueryParam = struct {
    name: []const u8,
    projections: []QueryProjection,
    from: *Type,
    filter: ?*Expr,
    /// `where has Type` presence filter.  Kept separate from `filter` so
    /// semantics can distinguish "row contains component" from a boolean
    /// expression over projected fields.
    has: ?*Type = null,
};

pub const QueryProjection = struct {
    mutable: bool,
    path: Path,
};

pub const TraitDecl = struct {
    name: []const u8,
    generics: []GenericParam,
    bounds: []*Type,
    /// Required method signatures.  Trait methods are declarations only: an
    /// `impl Trait for Type` block supplies the bodies.
    methods: []TraitMethod = &.{},
};

/// Method receiver in a trait requirement: `self`, `&self`, or `&mut self`.
pub const Receiver = struct {
    /// `false` for a by-value `self` receiver.
    by_ref: bool = true,
    mutable: bool = false,
};

pub const TraitParam = struct {
    /// `null` for signature-only parameters such as `&mut Gpu`; names are
    /// purely documentation in a trait requirement.
    name: ?[]const u8 = null,
    ty: *Type,
};

pub const TraitMethod = struct {
    attributes: []Attribute = &.{},
    visibility: ?Visibility = null,
    name: []const u8,
    is_async: bool = false,
    generics: []GenericParam = &.{},
    receiver: ?Receiver = null,
    params: []TraitParam = &.{},
    result: *Type,
    where_clause: ?WhereClause = null,
};

pub const ImplDecl = struct {
    generics: []GenericParam,
    trait_ty: ?*Type,
    target: *Type,
    where_clause: ?WhereClause,
    methods: []Method,
};

pub const Method = struct {
    attributes: []Attribute,
    visibility: ?Visibility,
    function: FunctionDecl,
};

pub const Binding = struct {
    name: []const u8,
    ty: ?*Type,
    mutable: bool,
    value: *Expr,
};

// ---------------------------------------------------------------------------
// Statements and blocks
// ---------------------------------------------------------------------------

pub const Block = struct {
    entries: []Entry,
};

pub const Entry = union(enum) {
    item: *Item,
    stmt: *Stmt,
};

pub const Stmt = union(enum) {
    binding: Binding,
    ret: ?*Expr,
    break_stmt,
    cont,
    while_stmt: WhileStmt,
    for_stmt: ForStmt,
    loop_stmt: LoopStmt,
    expr: *Expr,
    assign: AssignStmt,
    unsafe_block: *Block,
    uninitialized: UninitializedDecl,
    /// `disown commands`: releases the caller's claim on a world lease
    /// (typically a `Commands` handle produced by `await query`).  Front-end
    /// only for now: semantics/back ends treat it as a no-op.
    disown: *Expr,
};

pub const UninitializedDecl = struct {
    name: []const u8,
    ty: *Type,
    mutable: bool = true,
};

pub const WhileStmt = struct {
    condition: *Expr,
    body: *Block,
};

pub const ForStmt = struct {
    pattern: *Pattern,
    iterable: *Expr,
    body: *Block,
};

pub const LoopStmt = struct {
    body: *Block,
};

pub const AssignOp = enum {
    assign,
    add,
    sub,
    mul,
    div,
    mod,
};

pub const AssignStmt = struct {
    target: *Expr,
    op: AssignOp,
    value: *Expr,
};

// ---------------------------------------------------------------------------
// Expressions
// ---------------------------------------------------------------------------

pub const Expr = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
    boolean: bool,
    nil,
    error_literal: Path,
    path: Path,
    function: FunctionExpr,
    struct_literal: StructLiteral,
    map_literal: MapLiteral,
    list: []*Expr,
    block: *Block,
    if_expr: IfExpr,
    match_expr: MatchExpr,
    unary: Unary,
    prefix: Prefix,
    binary: Binary,
    range: Range,
    cast: Cast,
    call: Call,
    field: FieldAccess,
    index: Index,
    try_expr: *Expr,
    /// `query &mut Commands`: produces a task-like world lease.  Lowering is
    /// deferred to the ECS execution task; the front end models it so the
    /// `await query ...` DX parses and type-checks.
    query: QueryExpr,
    /// `{ a, b, c }` in expression position: an anonymous row value used by
    /// `commands.add_row(Table, { ... })`.
    row_literal: []*Expr,
};

pub const QueryExpr = struct {
    /// Requested lease type, normally a reference (`&mut Commands`).
    ty: *Type,
};

pub const StructLiteral = struct {
    path: Path,
    fields: []FieldInit,
};

pub const MapLiteral = struct {
    key_ty: *Type,
    value_ty: *Type,
    entries: []MapEntry,
};

pub const MapEntry = struct {
    key: *Expr,
    value: *Expr,
};

pub const FieldInit = struct {
    name: []const u8,
    value: *Expr,
};

pub const IfExpr = struct {
    branches: []IfBranch,
    else_body: ?*Block,
};

pub const IfBranch = struct {
    condition: *Expr,
    body: *Block,
};

pub const MatchExpr = struct {
    scrutinee: *Expr,
    arms: []MatchArm,
};

pub const MatchArm = struct {
    pattern: *Pattern,
    guard: ?*Expr,
    body: *Block,
};

pub const UnaryOp = enum {
    negative,
    not,
    borrow_shared,
    borrow_mut,
    deref,
};

pub const Unary = struct {
    op: UnaryOp,
    operand: *Expr,
};

pub const PrefixOp = enum { await_, spawn, detach, cancel };

pub const Prefix = struct {
    op: PrefixOp,
    operand: *Expr,
};

pub const BinaryOp = enum {
    or_,
    xor_,
    and_,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    add,
    sub,
    mul,
    div,
    mod,
};

pub const Binary = struct {
    op: BinaryOp,
    lhs: *Expr,
    rhs: *Expr,
};

pub const Range = struct {
    start: ?*Expr,
    end: ?*Expr,
    inclusive: bool,
};

pub const Cast = struct {
    expr: *Expr,
    ty: *Type,
};

pub const Call = struct {
    callee: *Expr,
    args: []*Expr,
    /// Turbofish type arguments attached to a method call
    /// (`commands.remove_component::<Held>(entity)`).
    type_args: []*Type = &.{},
};

pub const FieldAccess = struct {
    target: *Expr,
    name: []const u8,
};

pub const Index = struct {
    target: *Expr,
    /// One or more comma-separated subscript expressions: `m[i]`, `m[i, j]`.
    indices: []*Expr,
};

// ---------------------------------------------------------------------------
// Patterns
// ---------------------------------------------------------------------------

pub const Pattern = union(enum) {
    wildcard,
    literal: Literal,
    binding: []const u8,
    path: Path,
    tuple: []*Pattern,
    tuple_struct: TupleStructPattern,
    struct_pattern: StructPattern,
    or_pattern: []*Pattern,
};

pub const Literal = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
    boolean: bool,
    nil,
};

pub const TupleStructPattern = struct {
    path: Path,
    items: []*Pattern,
};

pub const StructPattern = struct {
    path: Path,
    fields: []FieldPattern,
};

pub const FieldPattern = struct {
    name: []const u8,
    pattern: ?*Pattern,
};
