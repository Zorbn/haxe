open Globals
open Common
open Type
open Typecore
open Typer
open Resolution
open Error

let create com macros =
	let ctx = {
		com = com;
		t = com.basic;
		g = {
			core_api = None;
			macros = macros;
			type_patches = Hashtbl.create 0;
			module_check_policies = [];
			delayed = [];
			debug_delayed = [];
			doinline = com.display.dms_inline && not (Common.defined com Define.NoInline);
			retain_meta = Common.defined com Define.RetainUntypedMeta;
			std_types = null_module;
			std = null_class;
			global_using = [];
			complete = false;
			type_hints = [];
			load_only_cached_modules = false;
			functional_interface_lut = new Lookup.pmap_lookup;
			do_macro = MacroContext.type_macro;
			do_load_macro = MacroContext.load_macro';
			do_load_module = TypeloadModule.load_module;
			do_load_type_def = Typeload.load_type_def;
			get_build_info = InstanceBuilder.get_build_info;
			do_format_string = format_string;
			do_load_core_class = Typeload.load_core_class;
		};
		m = {
			curmod = null_module;
			import_resolution = new resolution_list ["import";"typer"];
			own_resolution = None;
			enum_with_type = None;
			module_using = [];
			import_statements = [];
		};
		is_display_file = false;
		bypass_accessor = 0;
		meta = [];
		with_type_stack = [];
		call_argument_stack = [];
		pass = PBuildModule;
		macro_depth = 0;
		untyped = false;
		curfun = FunStatic;
		in_function = false;
		in_loop = false;
		in_display = false;
		allow_inline = true;
		allow_transform = true;
		get_build_infos = (fun() -> None);
		ret = mk_mono();
		locals = PMap.empty;
		type_params = [];
		curclass = null_class;
		curfield = null_field;
		tthis = mk_mono();
		opened = [];
		vthis = None;
		in_call_args = false;
		in_overload_call_args = false;
		delayed_display = None;
		monomorphs = {
			perfunction = [];
		};
		memory_marker = Typecore.memory_marker;
	} in
	ctx.g.std_types <- (try
		TypeloadModule.load_module ctx ([],"StdTypes") null_pos
	with
		Error { err_message = Module_not_found ([],"StdTypes") } ->
			try
				let std_path = Sys.getenv "HAXE_STD_PATH" in
				raise_typing_error ("Standard library not found. Please check your `HAXE_STD_PATH` environment variable (current value: \"" ^ std_path ^ "\")") null_pos
			with Not_found ->
				raise_typing_error "Standard library not found. You may need to set your `HAXE_STD_PATH` environment variable" null_pos
	);
	(* We always want core types to be available so we add them as default imports (issue #1904 and #3131). *)
	List.iter (fun mt ->
		ctx.m.import_resolution#add (module_type_resolution mt None null_pos))
	(List.rev ctx.g.std_types.m_types);
	List.iter (fun t ->
		match t with
		| TAbstractDecl a ->
			(match snd a.a_path with
			| "Void" -> ctx.t.tvoid <- TAbstract (a,[]);
			| "Float" -> ctx.t.tfloat <- TAbstract (a,[]);
			| "Int" -> ctx.t.tint <- TAbstract (a,[])
			| "Bool" -> ctx.t.tbool <- TAbstract (a,[])
			| "Dynamic" -> t_dynamic_def := TAbstract(a,extract_param_types a.a_params);
			| "Null" ->
				let mk_null t =
					try
						if not (is_null ~no_lazy:true t || is_explicit_null t) then TAbstract (a,[t]) else t
					with Exit ->
						(* don't force lazy evaluation *)
						let r = ref (lazy_available t_dynamic) in
						r := lazy_wait (fun() ->
							let t = (if not (is_null t) then TAbstract (a,[t]) else t) in
							r := lazy_available t;
							t
						);
						TLazy r
				in
				ctx.t.tnull <- mk_null;
			| _ -> ())
		| TEnumDecl _ | TClassDecl _ | TTypeDecl _ ->
			()
	) ctx.g.std_types.m_types;
	let m = TypeloadModule.load_module ctx ([],"String") null_pos in
	List.iter (fun mt -> match mt with
		| TClassDecl c -> ctx.t.tstring <- TInst (c,[])
		| _ -> ()
	) m.m_types;
	let m = TypeloadModule.load_module ctx ([],"Std") null_pos in
	List.iter (fun mt -> match mt with
		| TClassDecl c -> ctx.g.std <- c;
		| _ -> ()
	) m.m_types;
	let m = TypeloadModule.load_module ctx ([],"Array") null_pos in
	(try
		List.iter (fun t -> (
			match t with
			| TClassDecl ({cl_path = ([],"Array")} as c) ->
				ctx.t.tarray <- (fun t -> TInst (c,[t]));
				raise Exit
			| _ -> ()
		)) m.m_types;
		die "" __LOC__
	with Exit -> ());
	let m = TypeloadModule.load_module ctx (["haxe"],"EnumTools") null_pos in
	(match m.m_types with
	| [TClassDecl c1;TClassDecl c2] -> ctx.g.global_using <- (c1,c1.cl_pos) :: (c2,c2.cl_pos) :: ctx.g.global_using
	| [TClassDecl c1] ->
		let m = TypeloadModule.load_module ctx (["haxe"],"EnumWithType.valueTools") null_pos in
		(match m.m_types with
		| [TClassDecl c2 ] -> ctx.g.global_using <- (c1,c1.cl_pos) :: (c2,c2.cl_pos) :: ctx.g.global_using
		| _ -> die "" __LOC__);
	| _ -> die "" __LOC__);
	ignore(TypeloadModule.load_module ctx (["haxe"],"Exception") null_pos);
	ctx.g.complete <- true;
	ctx

;;
create_context_ref := create;
Inline.maybe_reapply_overload_call_ref := CallUnification.maybe_reapply_overload_call;
