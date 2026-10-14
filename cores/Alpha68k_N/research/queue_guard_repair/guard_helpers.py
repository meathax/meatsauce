def literal_flow_options(args: list[str]) -> dict[str,str]:
    """Inspect PowerShell parameter colon forms/unique abbreviations consistently."""
    protected={'-action','-stage','-globalslotroot','-globaltemproot','-quartusfast'}
    result={}
    for index,arg in enumerate(args):
        flag,sep,value=arg.lower().partition(':')
        matches=[name for name in protected if flag.startswith('-') and name.startswith(flag)]
        if len(matches)>1:raise Refusal('Ambiguous protected queue parameter')
        if not matches:continue
        name=matches[0]
        if name in result:raise Refusal('Duplicate protected queue parameter')
        if name=='-quartusfast':raise Refusal('Unknown fast delegate on canonical queue flow')
        if not sep:
            if index+1>=len(args):raise Refusal('Missing protected queue parameter value')
            value=args[index+1]
        result[name]=value
    return result


def validate_fast(args: list[str]) -> None:
    """Recognize only the reviewed visible build CLI; never authorize assembly."""
    if not args or args[0] != 'build':
        raise Refusal('Unsupported QuartusFast action; reviewed build CLI required')
    seen=set(); values={}; index=1
    value_flags={'--project','--mode','--threads'}
    bool_flags={'--no-fallback','--allow-rbf','--checks-only'}
    while index<len(args):
        flag=args[index]
        if flag not in value_flags|bool_flags or flag in seen:
            raise Refusal('Unknown or duplicate QuartusFast flag')
        seen.add(flag); index+=1
        if flag in value_flags:
            if index>=len(args):raise Refusal('Missing QuartusFast flag value')
            values[flag]=args[index]; index+=1
    project=values.get('--project','')
    if not ntpath.isabs(project) or ntpath.splitext(project)[1].lower()!='.qpf':
        raise Refusal('QuartusFast requires a literal absolute QPF path')
    if values.get('--mode','dev-fast') not in {'dev-fast','dev-safe','release'}:
        raise Refusal('Unknown QuartusFast mode')
    threads=values.get('--threads','2')
    if not threads.isascii() or not threads.isdecimal() or not 1<=int(threads)<=32:
        raise Refusal('Invalid QuartusFast thread count')
    if {'--allow-rbf','--checks-only'}<=seen:
        raise Refusal('Conflicting QuartusFast assembly/check flags')
    # --allow-rbf remains visible to ordinary approval review. Reviewed controller
    # routes that full compile through the shared FIFO; this hook acquires no lane.


class ReadonlyEvidence:
    """Finite typed AST grammar for literal Python evidence reads, never a runner.

    No eval/exec, subprocess, arbitrary imports/calls, attribute traversal, writes,
    user functions or dynamic Path values. Binding types prevent builtin shadowing.
    """
    def __init__(self):
        self.bindings={}; self.path_imported=False

    def bind(self, target, typ):
        if isinstance(target,ast.Name):
            if target.id in {'Path','print','enumerate','str','len'} or target.id.startswith('_'):
                raise ValueError('protected binding')
            self.bindings[target.id]=typ
        elif isinstance(target,(ast.Tuple,ast.List)) and isinstance(typ,tuple) and typ[0]=='tuple' and len(target.elts)==len(typ[1]):
            for item,value in zip(target.elts,typ[1]):self.bind(item,value)
        else:raise ValueError('unsupported binding')

    def element(self, typ):
        if typ=='str':return 'str'
        if isinstance(typ,tuple) and typ[0]=='seq':return typ[1]
        raise ValueError('not a bounded data sequence')

    def expr(self, node):
        if isinstance(node,ast.Constant) and type(node.value) in {str,int,bool,type(None)}:
            return type(node.value).__name__
        if isinstance(node,ast.Name):return self.bindings[node.id]
        if isinstance(node,(ast.List,ast.Tuple)):
            types=[self.expr(e) for e in node.elts]
            if isinstance(node,ast.Tuple):return ('tuple',types)
            if types and any(t!=types[0] for t in types):raise ValueError('mixed sequence')
            return ('seq',types[0] if types else 'str')
        if isinstance(node,ast.Subscript):
            typ=self.expr(node.value)
            if isinstance(node.slice,ast.Slice):
                for n in (node.slice.lower,node.slice.upper,node.slice.step):
                    if n is not None and self.expr(n)!='int':raise ValueError('slice type')
                self.element(typ);return typ
            if self.expr(node.slice)!='int':raise ValueError('index type')
            if isinstance(typ,tuple) and typ[0]=='tuple' and isinstance(node.slice,ast.Constant):return typ[1][node.slice.value]
            return self.element(typ)
        if isinstance(node,ast.UnaryOp) and isinstance(node.op,(ast.USub,ast.UAdd)) and self.expr(node.operand)=='int':return 'int'
        if isinstance(node,ast.UnaryOp) and isinstance(node.op,ast.Not):self.expr(node.operand);return 'bool'
        if isinstance(node,ast.Compare):
            if any(not isinstance(op,(ast.Eq,ast.NotEq,ast.Lt,ast.LtE,ast.Gt,ast.GtE,ast.In,ast.NotIn)) for op in node.ops):raise ValueError('comparison')
            for item in [node.left]+node.comparators:self.expr(item)
            return 'bool'
        if isinstance(node,ast.BoolOp):
            for item in node.values:self.expr(item)
            return 'bool'
        if isinstance(node,ast.BinOp) and isinstance(node.op,ast.Add):
            left=self.expr(node.left);right=self.expr(node.right)
            if left==right and left in {'str','int'}:return left
            raise ValueError('addition type')
        if isinstance(node,ast.BinOp) and isinstance(node.op,ast.Div) and self.expr(node.left)=='path' and isinstance(node.right,ast.Constant) and isinstance(node.right.value,str):return 'path'
        if isinstance(node,ast.JoinedStr):
            for item in node.values:
                if isinstance(item,ast.FormattedValue):
                    typ=self.expr(item.value)
                    if typ not in {'str','int','bool','NoneType'} or item.format_spec is not None:raise ValueError('format type')
                elif not isinstance(item,ast.Constant):raise ValueError('format node')
            return 'str'
        if isinstance(node,(ast.ListComp,ast.GeneratorExp)):
            for gen in node.generators:
                if gen.is_async:raise ValueError('async')
                self.bind(gen.target,self.element(self.expr(gen.iter)))
                for test in gen.ifs:self.expr(test)
            return ('seq',self.expr(node.elt))
        if isinstance(node,ast.Call):return self.call(node)
        raise ValueError('unsupported expression')

    def call(self,node):
        if any(kw.arg is None for kw in node.keywords):raise ValueError('expanded call')
        if isinstance(node.func,ast.Name):
            name=node.func.id
            if name=='print':
                if any(kw.arg not in {'sep','end'} or self.expr(kw.value)!='str' for kw in node.keywords):raise ValueError('print target')
                for arg in node.args:self.expr(arg)
                return 'NoneType'
            if name=='Path' and self.path_imported and len(node.args)==1 and not node.keywords and isinstance(node.args[0],ast.Constant) and isinstance(node.args[0].value,str) and ntpath.isabs(node.args[0].value):return 'path'
            if name=='enumerate' and len(node.args)==1 and not node.keywords:return ('seq',('tuple',['int',self.element(self.expr(node.args[0]))]))
            if name=='len' and len(node.args)==1 and not node.keywords:self.element(self.expr(node.args[0]));return 'int'
            if name=='str' and len(node.args)==1 and not node.keywords and self.expr(node.args[0]) in {'str','int','bool','NoneType','path'}:return 'str'
            raise ValueError('untrusted function')
        if not isinstance(node.func,ast.Attribute):raise ValueError('call shape')
        typ=self.expr(node.func.value);method=node.func.attr
        if typ=='path' and method=='read_text' and not node.args and all(kw.arg in {'encoding','errors'} and isinstance(kw.value,ast.Constant) and isinstance(kw.value.value,str) for kw in node.keywords):return 'str'
        if typ=='path' and method=='exists' and not node.args and not node.keywords:return 'bool'
        if typ=='str' and method=='splitlines' and not node.args and not node.keywords:return ('seq','str')
        if typ=='str' and method in {'lower','upper'} and not node.args and not node.keywords:return 'str'
        if typ=='str' and method=='join' and len(node.args)==1 and not node.keywords and self.element(self.expr(node.args[0]))=='str':return 'str'
        raise ValueError('untrusted method')

    def stmt(self,node):
        if isinstance(node,ast.ImportFrom) and node.module=='pathlib' and node.level==0 and len(node.names)==1 and node.names[0].name=='Path' and node.names[0].asname is None:
            self.path_imported=True;return
        if isinstance(node,ast.Assign) and len(node.targets)==1:self.bind(node.targets[0],self.expr(node.value));return
        if isinstance(node,ast.Expr) and isinstance(node.value,ast.Call) and isinstance(node.value.func,ast.Name) and node.value.func.id=='print':
            if any(kw.arg not in {'sep','end'} or self.expr(kw.value)!='str' for kw in node.value.keywords):raise ValueError('print target')
            for arg in node.value.args:self.expr(arg)
            return
        if isinstance(node,ast.For) and not node.orelse:
            self.bind(node.target,self.element(self.expr(node.iter)))
            for item in node.body:self.stmt(item)
            return
        if isinstance(node,ast.If):
            self.expr(node.test)
            # Each branch is independently checked; no unsafe callable bindings exist.
            for item in node.body+node.orelse:self.stmt(item)
            return
        if isinstance(node,ast.Expr):self.expr(node.value);return
        raise ValueError('unsupported statement')


def readonly_python(args: list[str]) -> bool:
    rest=list(args)
    if rest[:1]==['-B']:rest=rest[1:]
    if rest[:2]==['-X','utf8']:rest=rest[2:]
    if len(rest)!=2 or rest[0]!='-c' or len(rest[1])>16000:return False
    try:
        tree=ast.parse(rest[1])
        if sum(1 for _ in ast.walk(tree))>1500:return False
        checker=ReadonlyEvidence()
        for item in tree.body:checker.stmt(item)
        return True
    except (SyntaxError,ValueError,KeyError,IndexError,TypeError):return False
