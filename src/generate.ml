
open Printf
open Util
module StringMap = struct
	include Map.Make(String)
	let find_opt key map = try Some (find key map) with Not_found -> None
end

let rec mkdirp_in base dirs =
	let relpath = String.concat Filename.dir_sep dirs in
	let fullpath = Filename.concat base relpath in
	let fail () = failwith ("Not a directory: " ^ fullpath) in
	let open Unix in
	try
		if (stat fullpath).st_kind != S_DIR then fail ()
	with Unix_error (ENOENT, _, _) -> begin
		let () = match (List.rev dirs) with
			| [] -> fail ()
			| dir :: prefix -> mkdirp_in base (List.rev prefix)
		in
		mkdir fullpath 0o0750
	end

type update_mode = [
	| `clean
	| `unclean
]

type 'a generated_expression = [ | `reuse_existing | `expr of 'a ]

let main arg_idx args =
	let repo = ref "" in
	let dest = ref "" in
	let digest_map = ref "" in
	let update_mode = ref `clean in
	let num_versions = ref None in
	let package_selection = ref [] in
	let ignore_broken_packages = ref false in
	let offline = ref false in
	let opts = Arg.align [
		("--src", Arg.Set_string repo, "DIR Opam repository");
		("--dest", Arg.Set_string dest, "DIR Destination (must not exist, unless --unclean / --update given)");
		("--num-versions", Arg.String (fun n -> num_versions := Some n), "NUM Versions of each *-versioned package to keep (default: all. Format: x.x.x)");
		("--digest-map", Arg.Set_string digest_map, "FILE Digest mapping (digest.json; may exist)");
		("--offline", Arg.Set offline, "Offline mode (packages requiring download will fail)");
		("--unclean",
			Arg.Unit (fun () -> update_mode := `unclean),
			"(bool) Write into an existing destination (no cleanup, leaves existing files)"
		);

		("--ignore-broken", Arg.Set ignore_broken_packages, "(bool) skip over unprocessible packages (default: fail)");
	]; in
	let add_package p = package_selection := (match p with
			| "*" -> `All
			| p -> `Package (Repo.parse_package_spec p)
		) :: !package_selection
	in
	Arg.parse_argv ~current:(ref arg_idx) args opts add_package "usage: opam2nix generate [OPTIONS] [package@version [package2@*num-versions]]";
	
	(* fix up reversed package list *)
	let package_selection = List.rev !package_selection in
	let () = if List.length package_selection == 0 then (
		prerr_endline "no packages selected (did you mean '*'?)";
		exit 0
	) in

	let repo = nonempty !repo "--src" in
	let dest = nonempty !dest "--dest" in
	let digest_map = match !digest_map with
		| "" -> None
		| other -> Some other
	in
	let mode = !update_mode in
	let offline = !offline in

	let mkdir dest = Unix.mkdir dest 0o750 in

	let () = try
		mkdir dest
	with Unix.Unix_error(Unix.EEXIST, _, _) -> (
		match mode with
			| `clean ->
				Unix.rmdir dest;
				mkdir dest
			| `unclean ->
				Printf.eprintf "Adding to existing contents at %s\n" dest
	) in

	let cache = (match digest_map with
		| Some digest_map -> (
			FileUtil.mkdir ~parent:true (Filename.dirname digest_map);
			Printf.eprintf "Using digest mapping at %s\n" digest_map;
			try
				Digest_cache.try_load digest_map
			with e -> (
				Printf.eprintf "Error loading %s, you may need to delete or fix it manually\n" digest_map;
				raise e
			)
		)
		| None -> (
			Printf.eprintf "Note: not using a digest mapping, add one with --digest-map\n";
			Digest_cache.ephemeral
		)
	) in

	let deps = new Opam_metadata.dependency_map in

	let write_expr path expr =
		let oc = open_out path in
		Nix_expr.write oc expr;
		close_out oc
	in

	(* if `--num-versions is specified, swap the `All entries for a filter *)
	let package_selection : Repo.package_selection list = match !num_versions with
		| Some n ->
			let filter = Repo.parse_version_filter n in
			package_selection |> List.map (function
				| `All -> `Filtered filter
				| `Package (name, `All) -> `Package (name, filter)
				| other -> other
			)
		| None -> package_selection
	in

	let generated_versions = ref StringMap.empty in
	let mark_version_generated ~package version =
		let current = !generated_versions in
		generated_versions := match StringMap.find_opt package current with
			| Some versions ->
				StringMap.add package (version :: versions) current
			| None ->
				StringMap.add package [version] current
	in

	Repo.traverse `Opam ~repos:[repo] ~packages:package_selection (fun package version path ->
		let dest_parts = [package; (Repo.path_of_version `Nix version)] in
		let version_dir = String.concat Filename.dir_sep (dest :: dest_parts) in
		let dest_path = Filename.concat version_dir "default.nix" in
		let files_src = (Filename.concat path "files") in
		let has_files = Sys.file_exists files_src in

		let handle_error desc e =
			if !ignore_broken_packages then (
				prerr_endline ("Warn: " ^ desc); None
			) else raise e
		in
		let expr = (
			let open Opam_metadata in
			try
				Some (nix_of_opam ~cache ~offline ~deps ~has_files ~name:package ~version path)
			with
			| Unsupported_archive desc as e -> handle_error ("Unsupported archive: " ^ desc) e
			| Invalid_package desc as e -> handle_error ("Invalid package: " ^ desc) e
			| Checksum_mismatch desc as e -> handle_error ("Checksum mismatch: " ^ desc) e
			| Not_cached desc as e -> handle_error ("Resource not cached: " ^ desc) e
			| Download.Download_failed url as e -> handle_error ("Download failed: " ^ url) e
		) in
		expr |> Option.may (fun expr ->
			mkdirp_in dest dest_parts;
			let open FileUtil in
			cp [readlink (Filename.concat path "opam")] (Filename.concat version_dir "opam");
			let () =
				let filenames = if has_files then ls files_src else [] in
				match filenames with
					| [] -> ()
					| filenames ->
						(* copy all the files *)
						let files_dest = Filename.concat version_dir "files" in
						rm_r files_dest;
						mkdirp_in version_dir ["files"];
						cp ~recurse:true ~preserve:true ~force:Force filenames files_dest;
			in
			mark_version_generated ~package version;
			write_expr dest_path expr
		)
	);

	Digest_cache.save cache;

	Repo.traverse_versions `Nix ~root:dest (fun package versions base ->
		let import_version ver =
			(* If the version has special characters, quote it.
			* e.g `import ./fpo`, vs `import (./. + "/foo bar")`
			*)
			let path = Repo.path_of_version `Nix ver in
			`Lit ("import ./" ^ path ^ " world")
		in
		let path = Filename.concat base "default.nix" in
		write_expr path (
			`Function (`Id "world",
				`Attrs (Nix_expr.AttrSet.build (
					("latest", versions |> Repo.latest_version |> import_version) ::
					(versions |> List.map (fun ver -> (Repo.string_of_version ver), import_version ver))
				))
			)
		)
	);

	let () =
		let packages = list_dirs dest in
		let path_of_package = (fun p -> `Lit ("import ./" ^ p ^ " world")) in
		let path = Filename.concat dest "default.nix" in
		write_expr path (
			`Function (`Id "world",
				`Attrs (Nix_expr.AttrSet.build (
					packages |> List.map (fun ver -> ver, path_of_package ver)
				))
			)
		)
	in

	(* upon success, trim cache (unless we're doing an unclean run) *)
	(match mode with
		| `unclean -> ()
		| `clean ->
			Digest_cache.gc cache;
			Digest_cache.save cache;
	);

	(* Printf.eprintf "generated deps: %s\n" (deps#to_string) *)
	()
