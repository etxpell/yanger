%%%----------------------------------------------------------------%%%
%%% @doc Yanger Tree Output Plugin                                 %%%
%%% @author kris@tail-f.com (summer intern 2014)                   %%%
%%% Prints schema nodes (children) of the YANG data tree in ascii. %%%
%%%----------------------------------------------------------------%%%

-module(yanger_tree).
-behaviour(yanger_plugin).

-export([init/1, help/0]).

-include_lib("yanger/include/yang.hrl").

-define(search_one,    yang:search_one_stmt).
-define(stmt_arg,      yang:stmt_arg).
-define(stmt_kw,       yang:stmt_keyword).
-define(stmt_substmts, yang:stmt_substmts).
-define(in,            lists:member).

-type mode() :: data | rpc | input | output | notification.

-spec help() -> binary().
help() ->
<<"Each node is printed as:

<status> <flags> <name> <opts> <type> <if-features>

  <status> is one of:
    +  for current
    x  for deprecated
    o  for obsolete

  <flags> is one of:
    rw  for configuration data
    ro  for non-configuration data
    -x  for rpcs/actions
    -n  for notifications

  <name> is the name of the node
    (<name>) means that the node is a choice node
   :(<name>) means that the node is a case node

   If the node is augmented into the tree from another module, its
   name is printed as <prefix>:<name>.

  <opts> is one of:
    ?  for an optional leaf or choice
    !  for a presence container
    *  for a leaf-list or list
    [<keys>] for a list's keys

  <type> is the name of the type for leafs and leaf-lists
    If the type is a leafref, the type is printed as \"-> TARGET\", where
    TARGET is either the leafref path, with prefixed removed if possible.

  <if-features> is the list of features this node depends on, printed
    within curly brackets and a question mark \"{...}?\"
">>.

init(Ctx0) ->
    Ctx1 = yanger_plugin:register_output_format(Ctx0,
                                                tree,
                                                _AllowErrors = true,
                                                fun emit/3),
    Ctx2 = yanger_plugin:register_hook(
             Ctx1, #hooks.post_init_ctx, fun post_init_ctx/1),
   yanger_plugin:register_option_specs(Ctx2, option_specs()).

option_specs() ->
    [{"Tree output specific options:",
      [{tree_depth, undefined, "tree-depth", integer,
        "Number of levels to print"},
       {tree_path,  undefined, "tree-path", string,
        "Subtree to print"},
       {tree_help,  undefined, "tree-help", boolean,
        "Print help on tree symbols and exit"}]
     }].

post_init_ctx(Ctx) ->
    case proplists:get_value(tree_help, Ctx#yctx.options, false) of
        true ->
            io:put_chars(help()),
            halt();
        false ->
            ok
    end,
    Ctx.

-spec emit(#yctx{}, [#module{}], erlang:device()) -> ok.
emit(Ctx, Mods, Fd) ->
    Dep  = proplists:get_value(tree_depth, Ctx#yctx.options),
    PathStr = proplists:get_value(tree_path, Ctx#yctx.options, ""),
    Path = [?l2a(Name) || Name <- string:tokens(PathStr, "/")],
    emit_tree(Ctx, Mods, Mods, Fd, Dep, Path),
    %% If this format plugin will need to produce warnings or errors
    %% in the future, these warnings and errors need to be returned here.
    Errors = [],
    Errors.

-spec emit_tree(#yctx{}, [#module{}], [#module{}], erlang:device(),
                integer(), [atom()]) -> ok.
%% @doc Main emit function. Works through a list of modules and calls
%%      other sub emit functions appropriately.
emit_tree(_,   [],         _,       _,  _,     _   ) -> ok;
emit_tree(Ctx, [Mod|Mods], AllMods, Fd, Depth, Path) ->
    Chs    = [C || C <- Mod#module.children, is_data_def(C#sn.kind, Ctx)],
    Rpcs   = [C || C <- Mod#module.children, C#sn.kind == 'operation'],
    Notifs = [C || C <- Mod#module.children, C#sn.kind == 'notification'],
    AllModuleNames = [Mx#module.name|| Mx <- AllMods],
    Augs =
        lists:foldl(
          fun({RemoteModuleName, Augments}, Acc) ->
                  case lists:member(RemoteModuleName, AllModuleNames) of
                      true ->
                          Acc;
                      false ->
                          Augments ++ Acc
                  end
          end, [], Mod#module.remote_augments),

    if Chs == [] andalso Rpcs == [] andalso Notifs == [], Augs == [] ->
            skip;
       true ->
            print_header(Mod, Fd)
    end,
    print_list(Chs, Mod, Fd, Path, data, Depth),
    lists:foreach(
      fun(Augment) ->
              io:format(Fd, "augment ~s:~n", [?stmt_arg(Augment#augment.stmt)]),
              print_list(Augment#augment.children, Mod, Fd, Path, data, Depth)
      end, Augs),
    if Path == [] ->
            print_list(Rpcs, Mod, Fd, Path, rpc, Depth),
            print_list(Notifs, Mod, Fd, Path, notification, Depth);
       true ->
            ok
    end,
    emit_tree(Ctx, Mods, AllMods, Fd, Depth, Path).

print_list(Chs, Mod, Fd, Path, Mode, Depth) ->
    case (Chs == []) orelse (Mode == data) of
        true  -> skip;
        false -> io:format("~ss:~n", [Mode])
    end,
    print_children(Chs, Mod, Fd, undefined, " ", Path, Mode, Depth, 0).

print_header(Module, Fd) ->
    {Kw,ModArg,_,Substmts} = Module#module.stmt,
    Bstr = case ?search_one('belongs-to',Substmts) of
               false       -> "";
               {_,Arg,_,_} -> " (belongs-to " ++ ?a2l(Arg) ++ ")"
           end,
    io:format(Fd,"~s: ~s~s~n",[Kw, ModArg, Bstr]).

-spec print_children([#sn{}], #module{}, erlang:device(),
                     'undefined' | [atom()], string(), [atom()],
                     mode(), integer(), integer()) -> ok.
%% @doc Print a list of children, delegates to print_node.
%% special case, if Width is 0 initially, replace width to NWidth
%% special case, if Depth is 0, then don't do anything!
print_children(_, _, _, _, _, _, _, 0, _) ->
    skip;
print_children(Children, Mod, Fd, PKey, Prefix, Path, Mode, Depth, Width) ->
    NWidth = case Width of
                 0 -> width(0, Children, Mod);
                 _ -> Width
             end,
    {Children1, Path1} =
        case Path of
            [H|T] ->
                {[Sn || Sn <- Children, Sn#sn.name == H], T};
            _ ->
                {Children, Path}
        end,
    lists:foreach(
      fun(Child) ->
              LastChild   = lists:last(Children),
              NewPrefix = case Child == LastChild orelse
                              (LastChild#sn.kind == 'output' andalso
                               LastChild#sn.children == []) of
                              true  -> Prefix ++ "   ";
                              false -> Prefix ++ "  |"
                          end,
              case
                  (?in(Child#sn.kind,[input,output]))
                  andalso (Child#sn.children == [])
              of
                  true ->
                      skip;
                  false ->
                      NewMode =
                          if Child#sn.kind == 'input' -> input;
                             Child#sn.kind == 'output' -> output;
                             true -> Mode
                          end,
                      print_node(Child, Mod, Fd, PKey,
                                 NewPrefix, Path1, NewMode, Depth, NWidth)
              end
      end, Children1).

-spec print_node(#sn{}, #module{}, erlang:device(), 'undefined' | [atom()],
                 string(), undefined | [atom()], mode(),
                 integer(), integer()) -> ok.
print_node(Sn, Mod, Fd, PKey, Prefix, Path, Mode, Depth, Width) ->
    {KW, StmtArg, _, Subs} = Sn#sn.stmt,
    TypeName = typename(Sn#sn.type, Mod),
    {LsInit, _} = lists:split(length(Prefix)-1, Prefix),
    io:format(Fd, "~s~s--", [LsInit, status_str(Sn#sn.stmt)]),
    Name = name(Sn, Mod),
    Flags = flags_str(Sn, Mode),
    case KW of
        'list' ->
            io:format(Fd, "~s ~s*", [Flags, Name]);
        'container' ->
            case ?search_one(presence,Subs) of
                false -> NameAdd = Name;
                _     -> NameAdd = Name ++ "!"
            end,
            io:format(Fd,"~s ~s",[Flags,NameAdd]);
        'choice' ->
            MArg = ?stmt_arg(Mod#module.stmt),
            case
                (?search_one(mandatory,Subs) == false) orelse (MArg == false)
            of
                true -> io:format(Fd,"~s (~s)?",[Flags,StmtArg]);
                _    -> io:format(Fd,"~s (~s)", [Flags,StmtArg])
            end;
        'case' -> io:format(Fd,":(~s)",[StmtArg]);
        'leaf-list' ->
            io:format(Fd, "~s ~s~s",
                      [Flags, mk_str(Name ++ "*", Width+1),TypeName]);
        'leaf' ->
            NewName =
                case
                    PKey /= undefined
                    andalso ?in(Sn#sn.name, PKey)
                of
                    false ->
                        Mand = ?search_one(mandatory, Subs),
                        case
                            (Mand == false) orelse (?stmt_arg(Mand) == false)
                        of
                            true  -> mk_str(Name ++ "?", Width+1);
                            _     -> mk_str(Name, Width+1)
                        end;
                    true  -> mk_str(Name, Width+1)
                end,
            io:format(Fd, "~s ~s~s", [Flags, NewName, TypeName]);
        _ ->
            io:format(Fd, "~s ~s~s", [Flags, mk_str(Name, Width+1), TypeName])
    end,
    case (KW == list) andalso (?search_one(key, Subs) /= false) of
        true ->
            St  = ?search_one(key, Subs),
            Rep = re:replace(?stmt_arg(St),"\\s+"," ",[global,{return,list}]),
            io:format(Fd, " [~s]", [Rep]);
        _ ->
            skip
    end,
    case Sn#sn.if_feature of
        [] -> skip;
        F  -> Ls = [string:join([?b2l(?stmt_arg(St)) || {_,_,St} <- F],
                                ",")],
              io:format(Fd, " {~s}?", Ls)
    end,
    io:format("~n"),
    NewDepth = case Depth of
                   undefined -> Depth;
                   _         -> Depth - 1
               end,
    NewW = case ?in(KW, ['choice', 'case']) of
               true  -> Width;
               false -> 0
           end,
    print_children(Sn#sn.children, Mod, Fd, Sn#sn.keys,
                   Prefix, Path, Mode, NewDepth, NewW).

-spec is_data_def(atom(), #yctx{}) -> boolean().
is_data_def(Keyword, #yctx{env = #env{data_definition_stmts = D}}) ->
    Keyword /= 'rpc'
        andalso Keyword /= 'action'
        andalso Keyword /= 'notification'
        andalso yang:map_is_key(Keyword, D).

name(Sn, Mod) ->
    LocalName =
        case Sn#sn.name of
            {_, B} -> ?a2l(B);
            A -> ?a2l(A)
        end,
    if (Sn#sn.module)#module.modulename == Mod#module.modulename ->
            LocalName;
       true ->
            ?a2l((Sn#sn.module)#module.prefix) ++ ":" ++ LocalName
    end.

mk_str(Str,MinW) when length(Str) < MinW ->
    [Str, lists:duplicate(MinW - length(Str), " "), "   "];
mk_str(Str,_) ->
    [Str, "   "].

status_str(Stmt) ->
    case ?search_one(status, ?stmt_substmts(Stmt)) of
        {_, deprecated, _, _} -> "x";
        {_, obsolete, _, _}   -> "o";
        _                     -> "+"
    end.

flags_str(#sn{kind = Kind, config = Config}, Mode) ->
    if Mode == input        -> "-w";
       Kind == operation    -> "-x";
       Kind == notification -> "-n";
       Config == true       -> "rw";
       Config == false;
       Mode == output;
       Mode == notification -> "ro";
       true                 -> "--"
    end.

-spec typename(#type{} | atom(), #module{}) -> string().
%% @doc If there's a type description, return that string.
typename(undefined, _) ->
    "";
typename(Type, Mod) ->
    case ?stmt_arg(Type#type.stmt) of
        'leafref' -> leafref_ptr(Type#type.type_spec, Mod);
        {X,Y} -> ?a2l(X) ++ ":" ++ ?a2l(Y);
        X     -> ?a2l(X)
    end.

leafref_ptr(#leafref_type_spec{path_stmt = P}, Mod) ->
    PStr = ?b2l(?stmt_arg(P)),
    {Target, _} =
        lists:mapfoldl(
          fun(Part, CurPrefix) ->
                  case string:tokens(Part, ":") of
                      [CurPrefix, Name] ->
                          {Name, CurPrefix};
                      [NewPrefix, _Name] ->
                          {Part, NewPrefix};
                      Name ->
                          {Name, CurPrefix}
                  end
          end, ?a2l(Mod#module.prefix), string:tokens(PStr, "/")),
    ["-> ", if hd(PStr) == $/ -> "/";
               true -> ""
            end,
     string:join(Target, "/")].

%% @doc Get the width (amount of chars) of a list of children
width(W, Sns, Mod) ->
    lists:foldl(fun(Sn, AggW) ->
                        Nlen = string:len(name(Sn, Mod)),
                        case ?in(Sn#sn.kind, ['choice', 'case']) of
                            true -> width(AggW, Sn#sn.children, Mod);
                            false when Nlen > AggW -> Nlen;
                            false -> AggW
                        end
                end, W, Sns).
