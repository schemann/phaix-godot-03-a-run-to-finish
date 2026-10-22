extends SceneTree
## Headless tests for tutorial 03. From the repository root:
##   godot --headless --path godot/03-a-run-to-finish -s res://tests/run_tests.gd
## Prints PASS or FAIL per test and exits with 0 only if every test passed.
## `-- --only=text` runs the tests whose name contains the text (for example `-- --only=timer`).
##
## Saves: every level the tests load gets its own temporary save file (OS temp dir, wiped
## first), so a test run never reads or writes the real best_times.json. A few tests damage a file or write to a missing folder on
## purpose: the game logs a WARNING line for each of those, that is expected.

const Chain := preload("res://steps/step_02_goal_room/room_chain.gd") ## Steps 2 to 6 share this file.
const OldChain := preload("res://steps/step_00_start/room_chain.gd") ## Tutorial 01's chain: steps 0 and 1.
const Autopilot := preload("res://tools/autopilot.gd")
const BestTimes := preload("res://steps/step_06_best_time/best_times.gd")

const STEPS: Array[String] = [
	"step_00_start",
	"step_01_room_counter",
	"step_02_goal_room",
	"step_03_game_states",
	"step_04_run_timer",
	"step_05_restart",
	"step_06_best_time",
]
const ROOM_TYPES: Array[String] = ["straight", "long", "turn_left", "turn_right", "wide"]

## What each step changes against the one before (file names; .uid files do not count).
const CHANGES: Dictionary[String, Dictionary] = {
	"step_01_room_counter": {changed = ["level.gd", "main.tscn"], added = ["hud.gd"]},
	"step_02_goal_room": {changed = ["hud.gd", "level.gd", "room.gd", "room_chain.gd"], added = ["room_goal.tscn"]},
	"step_03_game_states": {changed = ["hud.gd", "level.gd", "main.tscn", "player.gd", "room.gd"], added = []},
	"step_04_run_timer": {changed = ["hud.gd", "level.gd", "main.tscn"], added = []},
	"step_05_restart": {changed = ["level.gd", "main.tscn"], added = []},
	"step_06_best_time": {changed = ["hud.gd", "level.gd", "main.tscn"], added = ["best_times.gd"]},
}

const STATE_READY := 0 ## Level.State, checked by test_state_enum.
const STATE_RUNNING := 1
const STATE_FINISHED := 2

const RAY_HEIGHT := 1.2 ## Metres above the floor: through the middle of a doorway.
const CEILING_LAYER := 2 ## VisualInstance3D.layers of the ceilings and lamp blocks: layer 2 only.
const ALL_LAYERS := 1048575 ## Camera3D.cull_mask default: all 20 layers.
const WALL_THICKNESS := 0.2 ## Studio graybox standard: interior wall 0.1-0.25 x 3.0 m.
const WALL_HEIGHT := 3.0
const SLAB_THICKNESS := 0.2 ## Floor and ceiling.
const DOORWAY_WIDTH := 1.6
const DOORWAY_HEIGHT := 2.4
const MATERIAL_DIR := "res://materials/"
const SEED_COUNT := 1000
const ROOMS_PER_SEED := 300
const GOAL_SEEDS := 500 ## Seeds 1..500 for the goal room placement.
const MAX_EXTRA_ROOMS := 3 ## The goal may wait at most this many rooms for a free place.
const STREAM_ROOMS := 10 ## How many rooms the streaming test walks through.
const SPEED_UP := 4 ## The walking tests run this many times faster than real time.
const SHORT_GOAL := 3 ## Goal room of the quick runs.

## Counts the script errors the engine logs. A test that hits one stops at that line and the engine hands back an
## empty array, which reads as a pass: `_report` charges the count to the test that ran.
class ScriptErrorCounter extends Logger:
	var count := 0
	var _lock := Mutex.new() ## The engine calls a logger from any thread.

	func _log_error(_function: String, _file: String, _line: int, _code: String, _rationale: String, _editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != ERROR_TYPE_SCRIPT:
			return
		_lock.lock()
		count += 1
		_lock.unlock()

var _passed := 0
var _failed := 0
var _skipped := 0
var _script_errors := ScriptErrorCounter.new() ## Registered with the engine's logger for the whole run.
var _script_errors_reported := 0 ## How many script errors the tests reported so far have been charged with.
var _save_dir := ""
var _save_counter := 0

func _initialize() -> void:
	OS.add_logger(_script_errors)
	await process_frame
	var started := Time.get_ticks_msec()
	_save_dir = OS.get_temp_dir().path_join("phaix-godot-03-tests")
	_wipe_save_dir()

	await _run("code rules: no class_name, no global random, no wall clock, input only through named actions", test_code_rules)
	await _run("code rules: the HUD only reads the level", test_hud_reads_only)
	await _run("steps: each step changes only what its concept needs, everything else is copied forward", test_copy_forward)
	await _run("step_00_start: tutorial 01's final state, file for file (only the folder name differs)", test_step_zero_is_tutorial_01)
	await _run("step_00_start / step_01_room_counter: the chain is tutorial 01's", test_old_chain_files)
	await _run("chain (tutorial 01): same seed gives the same plans 0-99, another seed another ones", test_determinism.bind(OldChain, false))
	await _run("chain (with goal): same seed gives the same plans 0-99, another seed another ones", test_determinism.bind(Chain, true))
	await _run("chain: seeds 1-%d x %d rooms, no overlap, no fallback, never backwards" % [SEED_COUNT, ROOMS_PER_SEED], test_no_overlap)
	await _run("goal: plan %d is the goal room, once, last, no overlap, no U-turn, seeds 1-%d" % [20, GOAL_SEEDS], test_goal_placement)
	await _run("goal: the plans before the goal are tutorial 01's rooms (seeds 1-200)", test_goal_keeps_old_rooms)
	await _run("goal: other goal rooms (1, 2, 7, 50, 120), 100 seeds each", test_goal_other_indices)
	await _run("goal: a goal that does not fit waits for the next room, and the plans stay valid", test_goal_waits)
	await _run("materials: shared graybox materials, 1 m grid, orange door, gold goal, emissive fixture, no private materials", test_materials)
	for room_type in ROOM_TYPES:
		await _run("room_%s: entrance, exit, doorway size, bounds" % room_type, test_room_module.bind(room_type))
	for step in _steps_from("step_02_goal_room"):
		await _run("%s room_goal: entrance only, 10 x 14, raised pad 3 x 3 in gold, its own light and fixture, trigger on the player layer" % step, test_goal_room.bind(step))
	for step in STEPS:
		await _run("%s: every room is closed (0.2 m floor, walls and ceiling), lamp and fixture, shared materials" % step, test_graybox_rooms.bind(step))
		await _run("%s: ambient fill reads inside closed rooms, the sun casts shadows" % step, test_lighting.bind(step))
		await _run("%s: every Entrance is on the previous Exit" % step, test_snapping.bind(step))
	for step in STEPS:
		await _run("%s: walks on the floor, relative to its facing" % step, test_walk.bind(step))
		await _run("%s: jumps about 1 m, stays below the ceiling and lands" % step, test_jump.bind(step))
		await _run("%s: the player's camera sees the ceiling" % step, test_player_camera.bind(step))
		await _run("%s: the sealed entrance of room 0 holds" % step, test_sealed_entrance.bind(step))
		await _run("%s: right stick turns the body and tilts the head, clamped at 89 deg" % step, test_stick_look.bind(step))
		await _run("%s: mouse look maths (0.002 rad per pixel, clamped)" % step, test_mouse_math.bind(step))
	if DisplayServer.get_name() == "headless":
		_skip("mouse capture: Esc releases, a click recaptures; the mouse is released at the finish and captured again by a restart", "the headless display server never reports a captured mouse; tools/capture.gd checks it in a window")
	for step in STEPS:
		await _run("%s: a door in the accent material opens on approach, lets a ray pass when open and blocks when closed" % step, test_door.bind(step))
		await _run("%s: a door never closes on the player" % step, test_door_waits_for_the_swing.bind(step))
		await _run("%s: a player sliding past the free end of an open door leaf keeps moving" % step, test_open_leaf_end.bind(step))
	for step in STEPS:
		await _run("%s: rooms stream in and out through %d rooms" % [step, STREAM_ROOMS], test_streaming.bind(step))
	for step: String in ["step_00_start", "step_06_best_time"]:
		await _run("%s: the plans do not depend on when the player walks" % step, test_timing_independence.bind(step))
	for step in STEPS:
		await _run("%s: the map starts visible, Tab toggles it" % step, test_toggle_map.bind(step))
		await _run("%s: the map reads data only" % step, test_map_reads_data_only.bind(step))
	for step in _steps_from("step_01_room_counter"):
		await _run("%s: the HUD counter reads \"Room N / goal\", follows the player and fits the screen" % step, test_counter.bind(step))
	for step in _steps_from("step_02_goal_room"):
		await _run("%s: the run ends in the goal room (no door, a pad to walk onto)" % step, test_goal_in_level.bind(step))
	await _run("state: the enum is READY, RUNNING, FINISHED in every step that has it", test_state_enum)
	for step in _steps_from("step_03_game_states"):
		await _run("%s: READY in room 0, RUNNING when the first door opens, FINISHED on the goal pad, input ignored after" % step, test_states.bind(step))
	for step in _steps_from("step_03_game_states"):
		await _run("%s: the finish panel is centred and hidden until the finish" % step, test_finish_panel.bind(step))
	await _run("timer: format_time cuts to tenths (0:00.0, 0:42.3, 1:00.0 ...)", test_format_time)
	for step in _steps_from("step_04_run_timer"):
		await _run("%s: the timer adds physics deltas only, never the wall clock, and stops at the finish" % step, test_timer.bind(step))
	for step: String in ["step_00_start", "step_01_room_counter", "step_02_goal_room", "step_03_game_states", "step_04_run_timer"]:
		await _run("%s: R restarts with seed + 1 (tutorial 01's meaning)" % step, test_regenerate_old.bind(step))
	for step in _steps_from("step_05_restart"):
		await _run("%s: R restarts the same seed, N starts seed + 1, both through start()" % step, test_restart.bind(step))
	await _run("restart: the reset lives in start() and nowhere else", test_reset_in_one_place)
	for step in STEPS:
		await _run("%s: R (and N from step 5) pressed at the first door do not open the door of the new room 0" % step, test_restart_at_the_door.bind(step))
	await _run("best times: a saved time loads again (round trip), the file has the documented shape", test_best_round_trip)
	await _run("best times: only a faster time replaces the best", test_best_only_faster)
	await _run("best times: no file is an empty list and loading writes nothing", test_best_missing_file)
	await _run("best times: a damaged file is kept as .bad, the list starts empty, no crash", test_best_damaged_file)
	await _run("best times: unknown keys and odd entries survive a rewrite", test_best_unknown_keys)
	await _run("best times: the save goes through a temp file, a stale temp file does no harm", test_best_atomic_write)
	await _run("best times: a save that cannot be written does not crash and keeps the time in memory", test_best_write_failure)
	await _run("best time: the HUD shows \"Best 0:39.8\" for the current seed and follows N", test_best_label)
	await _run("best time: a faster run says \"New best!\" and is saved, a slower one is not", test_best_in_level)
	await _run("full run: seed 42, goal room 20, the autopilot walks from room 0 to the goal and the best time is saved", test_full_run)
	for step in STEPS:
		await _run("%s: main scene runs 30 frames" % step, test_scene_runs.bind(step))

	_wipe_save_dir()
	OS.remove_logger(_script_errors)
	print("\n%d passed, %d failed, %d skipped in %.1f s" % [_passed, _failed, _skipped, (Time.get_ticks_msec() - started) / 1000.0])
	quit(1 if _failed > 0 else 0)

## Runs one test unless a `-- --only=text` argument asks for other tests only.
func _run(test_name: String, test: Callable) -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--only=") and not test_name.contains(argument.trim_prefix("--only=")):
			return
	var failures: Array[String] = await test.call()
	_report(test_name, failures)

func _steps_from(first: String) -> Array[String]:
	var result: Array[String] = []
	for step: String in STEPS.slice(STEPS.find(first)):
		result.append(step)
	return result

#region Source rules

func test_code_rules() -> Array[String]:
	var failures: Array[String] = []
	var global_random := RegEx.create_from_string("(^|[^.\\w])(randi|randf|randi_range|randf_range|randomize|pick_random)\\(")
	var wall_clock := RegEx.create_from_string("(Time\\.get_|OS\\.get_ticks|OS\\.get_unix|OS\\.delay)")
	var scripts := _scripts_in("res://steps")
	_expect(failures, scripts.size() >= 40, "found only %d scripts under steps" % scripts.size())
	for path in scripts:
		var source := FileAccess.get_file_as_string(path)
		var lines := source.split("\n")
		for i in lines.size():
			var line := lines[i].strip_edges()
			if line.begins_with("##") or line.begins_with("#"):
				continue
			var where := "%s:%d" % [path.trim_prefix("res://"), i + 1]
			_expect(failures, not line.begins_with("class_name"), "%s: class_name" % where)
			_expect(failures, global_random.search(line) == null, "%s: global random call" % where)
			_expect(failures, wall_clock.search(line) == null, "%s: reads the wall clock (the run time comes from the physics delta)" % where)
			_expect(failures, not line.contains(".shuffle("), "%s: Array.shuffle() uses the global generator" % where)
			_expect(failures, not line.contains("Input.is_key_pressed") and not line.contains("Input.is_physical_key_pressed"), "%s: reads a key directly" % where)
			_expect(failures, not line.contains("Input.is_mouse_button_pressed") and not line.contains("get_joy_axis") and not line.contains("is_joy_button_pressed"), "%s: reads a device directly" % where)
			_expect(failures, not line.contains("event is InputEventKey") and not line.contains("event is InputEventJoypad"), "%s: reads a key or button event directly" % where)
	# Gameplay state is never written in _process.
	for step in _steps_from("step_04_run_timer"):
		var level_source := FileAccess.get_file_as_string("res://steps/%s/level.gd" % step)
		_expect(failures, not level_source.contains("func _process("), "%s/level.gd has a _process: the clock belongs in _physics_process" % step)
		_expect(failures, level_source.contains("func _physics_process(delta: float)") and level_source.contains("run_time += delta"), "%s/level.gd does not add the physics delta" % step)
	return failures

func _scripts_in(dir_path: String) -> Array[String]:
	var found: Array[String] = []
	var dir := DirAccess.open(dir_path)
	for sub in dir.get_directories():
		found.append_array(_scripts_in(dir_path.path_join(sub)))
	for file in dir.get_files():
		if file.ends_with(".gd"):
			found.append(dir_path.path_join(file))
	return found

func test_hud_reads_only() -> Array[String]:
	var failures: Array[String] = []
	var assignment := RegEx.create_from_string("\\blevel\\.[\\w.]+\\s*(=|\\+=|-=)[^=]")
	var call_that_changes := RegEx.create_from_string("\\blevel\\.(start|_set_state|_spawn_room)\\(")
	for step in _steps_from("step_01_room_counter"):
		var lines := FileAccess.get_file_as_string("res://steps/%s/hud.gd" % step).split("\n")
		for i in lines.size():
			var line := lines[i].strip_edges()
			if line.begins_with("#"):
				continue
			_expect(failures, assignment.search(line) == null and call_that_changes.search(line) == null, "%s/hud.gd:%d changes the level: %s" % [step, i + 1, line])
	return failures

## The steps are copies of each other: a file only differs where the step's concept needs it.
func test_copy_forward() -> Array[String]:
	var failures: Array[String] = []
	for i in range(1, STEPS.size()):
		var before := STEPS[i - 1]
		var after := STEPS[i]
		var before_files := _step_files(before)
		var after_files := _step_files(after)
		var changed: Array[String] = []
		var added: Array[String] = []
		for file in before_files:
			if not after_files.has(file):
				failures.append("%s lost %s" % [after, file])
			elif _step_text(before, file) != _step_text(after, file):
				changed.append(file)
		for file in after_files:
			if not before_files.has(file):
				added.append(file)
		changed.sort()
		added.sort()
		var expected: Dictionary = CHANGES[after]
		_expect(failures, changed == expected.changed, "%s changes %s, expected %s" % [after, changed, expected.changed])
		_expect(failures, added == expected.added, "%s adds %s, expected %s" % [after, added, expected.added])
	return failures

func _step_files(step: String) -> Array[String]:
	var files: Array[String] = []
	for file in DirAccess.get_files_at("res://steps/" + step):
		if not file.ends_with(".uid"):
			files.append(file)
	return files

## The file's text with the step folder name blanked out, so copies compare equal.
func _step_text(step: String, file: String) -> String:
	return FileAccess.get_file_as_string("res://steps/%s/%s" % [step, file]).replace(step, "STEP")

func test_step_zero_is_tutorial_01() -> Array[String]:
	var failures: Array[String] = []
	var original := ProjectSettings.globalize_path("res://").path_join("../01-rooms-and-doors/steps/step_09_debug_map").simplify_path()
	if not DirAccess.dir_exists_absolute(original):
		_skip("step_00_start equals tutorial 01's step 9", "tutorial 01 is not next to this project")
		return failures
	var count := 0
	for file in DirAccess.get_files_at(original):
		if file.ends_with(".uid"):
			continue
		count += 1
		var theirs := FileAccess.get_file_as_string(original.path_join(file)).replace("step_09_debug_map", "STEP")
		_expect(failures, theirs == _step_text("step_00_start", file), "%s differs from tutorial 01's step 9" % file)
	_expect(failures, count == _step_files("step_00_start").size(), "step_00_start has %d files, tutorial 01's step 9 has %d" % [_step_files("step_00_start").size(), count])
	return failures

func test_old_chain_files() -> Array[String]:
	var failures: Array[String] = []
	_expect(failures, _step_text("step_00_start", "room_chain.gd") == _step_text("step_01_room_counter", "room_chain.gd"), "steps 0 and 1 do not share room_chain.gd")
	for step in _steps_from("step_03_game_states"):
		_expect(failures, _step_text("step_02_goal_room", "room_chain.gd") == _step_text(step, "room_chain.gd"), "%s changed room_chain.gd" % step)
	return failures

#endregion

#region Chain (pure data, no scene)

func test_determinism(chain_script: GDScript, with_goal: bool) -> Array[String]:
	var failures: Array[String] = []
	var first := _plans(chain_script, 42, 100, with_goal)
	var second := _plans(chain_script, 42, 100, with_goal)
	var other := _plans(chain_script, 43, 100, with_goal)
	_expect(failures, first.size() == 100, "made %d plans, expected 100" % first.size())
	_expect(failures, _same_plans(first, second), "seed 42 twice: the plans differ")
	_expect(failures, not _same_plans(first, other), "seed 43 gives the same plans as seed 42")
	for i in first.size():
		_expect(failures, first[i].index == i, "plan %d has index %d" % [i, first[i].index])
	return failures

func test_no_overlap() -> Array[String]:
	var failures: Array[String] = []
	var types_seen := {}
	for chain_seed in range(1, SEED_COUNT + 1):
		# Goal far away: this checks the ordinary rooms.
		var plans := _plans(OldChain, chain_seed, ROOMS_PER_SEED, false)
		for plan: Object in plans:
			types_seen[plan.type] = true
		failures.append_array(_chain_problems(plans, "seed %d" % chain_seed))
		if failures.size() > 8:
			break
	_expect(failures, types_seen.size() == OldChain.SCENES.size(), "only %d of %d room types were ever chosen" % [types_seen.size(), OldChain.SCENES.size()])
	return failures

## Overlaps with any earlier plan, headings that turn back, and snaps that do not meet.
## `plans` is the history of one chain; the last plan may be a goal room (it has no exit).
func _chain_problems(plans: Array, label: String) -> Array[String]:
	var problems: Array[String] = []
	# Sweep over x: a room can only overlap rooms whose x range reaches it.
	var by_x := plans.duplicate()
	by_x.sort_custom(func(a: Object, b: Object) -> bool: return a.bounds.position.x < b.bounds.position.x)
	for i in by_x.size():
		var a: Object = by_x[i]
		var inner: AABB = (a.bounds as AABB).grow(-OldChain.SHRINK)
		for j in range(i + 1, by_x.size()):
			var b: Object = by_x[j]
			if b.bounds.position.x > a.bounds.end.x:
				break
			if inner.intersects(b.bounds) or (b.bounds as AABB).grow(-OldChain.SHRINK).intersects(a.bounds):
				problems.append("%s: rooms %d and %d overlap" % [label, a.index, b.index])
	var start: Vector3 = plans[0].transform.origin
	for k in range(1, plans.size() - 1):
		# The next room's entrance has no rotation, so its basis is the heading of this exit.
		var heading: Vector3 = -(plans[k + 1].transform as Transform3D).basis.z
		var to_start := (start - (plans[k].transform as Transform3D).origin).normalized()
		if heading.dot(OldChain.START_HEADING) < -OldChain.BACK_LIMIT or heading.dot(to_start) > OldChain.BACK_LIMIT + 0.001:
			problems.append("%s: room %d heads back (heading %s)" % [label, k, heading.snapped(Vector3.ONE * 0.01)])
	return problems

## The first `count` plans. With a goal the chain is asked for a goal room far behind them.
func _plans(chain_script: GDScript, chain_seed: int, count: int, with_goal: bool) -> Array:
	var chain: RefCounted = chain_script.new(chain_seed, 100000) if with_goal else chain_script.new(chain_seed)
	for i in count:
		chain.next_plan()
	return chain.plans

func _same_plans(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if a[i].index != b[i].index or a[i].type != b[i].type or a[i].transform != b[i].transform or a[i].bounds != b[i].bounds:
			return false
	return true

#endregion

#region The goal room in the chain

## All plans of a chain up to and including its goal room (at most `limit` plans).
func _plans_to_goal(chain_seed: int, goal_room: int, limit := 400) -> RefCounted:
	var chain: RefCounted = Chain.new(chain_seed, goal_room)
	while chain.plans.size() < limit:
		var plan: Object = chain.next_plan()
		if plan.type == Chain.Type.GOAL:
			break
	return chain

func test_goal_placement() -> Array[String]:
	var failures: Array[String] = []
	var waited := 0
	var max_extra := 0
	for chain_seed in range(1, GOAL_SEEDS + 1):
		var chain := _plans_to_goal(chain_seed, 20)
		var plans: Array = chain.plans
		var goals: Array[int] = []
		for plan: Object in plans:
			if plan.type == Chain.Type.GOAL:
				goals.append(plan.index)
		if goals.size() != 1 or goals[0] != plans.size() - 1:
			failures.append("seed %d: goal rooms at %s of %d plans" % [chain_seed, goals, plans.size()])
			continue
		var extra: int = goals[0] - 20
		max_extra = maxi(max_extra, extra)
		waited += 1 if extra > 0 else 0
		if extra < 0 or extra > MAX_EXTRA_ROOMS:
			failures.append("seed %d: the goal room is plan %d, expected 20 to %d" % [chain_seed, goals[0], 20 + MAX_EXTRA_ROOMS])
		_expect(failures, chain.goal_index == goals[0], "seed %d: goal_index %d but the goal is plan %d" % [chain_seed, chain.goal_index, goals[0]])
		failures.append_array(_chain_problems(plans, "seed %d" % chain_seed))
		if failures.size() > 8:
			break
	print("        goal room: seeds 1-%d, %d needed to wait, the longest wait was %d rooms" % [GOAL_SEEDS, waited, max_extra])
	return failures

## Adding the goal room does not reshuffle the rooms before it: the same seed builds tutorial 01's rooms.
func test_goal_keeps_old_rooms() -> Array[String]:
	var failures: Array[String] = []
	for chain_seed in range(1, 201):
		var with_goal: Array = _plans_to_goal(chain_seed, 20).plans
		var without: Array = _plans(OldChain, chain_seed, 20, false)
		var same := true
		for i in 20:
			if with_goal[i].type != without[i].type or with_goal[i].transform != without[i].transform or with_goal[i].bounds != without[i].bounds:
				same = false
		_expect(failures, same, "seed %d: the rooms before the goal differ from tutorial 01's" % chain_seed)
		if failures.size() > 8:
			break
	return failures

func test_goal_other_indices() -> Array[String]:
	var failures: Array[String] = []
	for goal_room: int in [1, 2, 7, 50, 120]:
		for chain_seed in range(1, 101):
			var chain := _plans_to_goal(chain_seed, goal_room)
			var plans: Array = chain.plans
			var last: Object = plans[-1]
			_expect(failures, last.type == Chain.Type.GOAL, "goal %d seed %d: the chain does not end in a goal room" % [goal_room, chain_seed])
			_expect(failures, last.index >= goal_room and last.index <= goal_room + MAX_EXTRA_ROOMS, "goal %d seed %d: goal room is plan %d" % [goal_room, chain_seed, last.index])
			failures.append_array(_chain_problems(plans, "goal %d seed %d" % [goal_room, chain_seed]))
			if failures.size() > 8:
				return failures
	return failures

## The wait itself. A goal that never fits is faked: the goal's box is blown up to 2 km, so it hits
## the history wherever it is placed. (The test reaches into the chain's private module list; the
## shipped rooms always find a free place, see test_goal_placement.)
func test_goal_waits() -> Array[String]:
	var failures: Array[String] = []
	for chain_seed: int in [42, 7, 313]:
		var chain: RefCounted = Chain.new(chain_seed, 6)
		var real_bounds: AABB = chain._modules[Chain.Type.GOAL].bounds
		for i in 6:
			chain.next_plan()
		chain._modules[Chain.Type.GOAL].bounds = AABB(Vector3(-1000.0, -10.0, -1000.0), Vector3(2000.0, 20.0, 2000.0))
		for waited in 3:
			var plan: Object = chain.next_plan()
			_expect(failures, plan.type != Chain.Type.GOAL, "seed %d: an unfit goal room was placed as plan %d" % [chain_seed, plan.index])
			_expect(failures, plan.index == 6 + waited and chain.goal_index == 7 + waited, "seed %d: plan %d, goal_index %d after %d waits" % [chain_seed, plan.index, chain.goal_index, waited + 1])
		chain._modules[Chain.Type.GOAL].bounds = real_bounds # free again
		var goal: Object = chain.next_plan()
		_expect(failures, goal.type == Chain.Type.GOAL and goal.index == 9 and chain.goal_index == 9, "seed %d: after the wait the goal is plan %d (goal_index %d), expected 9" % [chain_seed, goal.index, chain.goal_index])
		failures.append_array(_chain_problems(chain.plans, "seed %d after the wait" % chain_seed))
		# The same story twice gives the same plans.
		var again: RefCounted = Chain.new(chain_seed, 6)
		for i in 6:
			again.next_plan()
		again._modules[Chain.Type.GOAL].bounds = AABB(Vector3(-1000.0, -10.0, -1000.0), Vector3(2000.0, 20.0, 2000.0))
		for i in 3:
			again.next_plan()
		again._modules[Chain.Type.GOAL].bounds = real_bounds
		again.next_plan()
		_expect(failures, _same_plans(chain.plans, again.plans), "seed %d: the waiting chain is not reproducible" % chain_seed)
	return failures

#endregion

#region Rooms and snapping (scene + physics)

func test_room_module(room_type: String) -> Array[String]:
	var failures: Array[String] = []
	var room: Node3D = (load("res://steps/step_00_start/room_%s.tscn" % room_type) as PackedScene).instantiate()
	root.add_child(room)
	# The room puts a closed door in its exit; this test is about the doorway itself.
	(room.get("door") as Node).free()
	await _wait_physics(5)
	var entrance: Marker3D = room.get_node("Entrance")
	var exit_point: Marker3D = room.get_node("Exit")
	var inside_shape: CollisionShape3D = room.get_node("Inside/CollisionShape3D")
	var bounds: AABB = inside_shape.transform * AABB(-(inside_shape.shape as BoxShape3D).size / 2.0, (inside_shape.shape as BoxShape3D).size)
	var centre := bounds.get_center()
	centre.y = 0.0

	_expect(failures, is_zero_approx(entrance.position.y) and is_zero_approx(exit_point.position.y), "markers are not at floor level")
	_expect(failures, (centre - entrance.position).dot(-entrance.global_basis.z) > 1.0, "Entrance -Z does not point into the room")
	_expect(failures, (exit_point.position - centre).dot(-exit_point.global_basis.z) > 1.0, "Exit -Z does not point out of the room")
	_expect(failures, entrance.transform.basis.is_equal_approx(Basis.IDENTITY), "Entrance is rotated")
	# The Inside box covers the footprint including the walls (the CSG shell).
	var floor_box: CSGBox3D = room.get_node("Shell/Floor")
	var floor_aabb := floor_box.transform * AABB(-floor_box.size / 2.0, floor_box.size)
	_expect(failures, bounds.size.x == floor_aabb.size.x and bounds.size.z == floor_aabb.size.z, "Inside box %s does not match the floor %s" % [bounds.size, floor_aabb.size])
	_expect(failures, is_equal_approx(bounds.size.y, WALL_HEIGHT), "Inside box is %.2f m high, walls are 3 m" % bounds.size.y)
	for wall_name: String in ["WallEntrance", "WallFar", "WallLeft", "WallRight"]:
		var wall: CSGBox3D = room.get_node("Shell/" + wall_name)
		_expect(failures, is_equal_approx(wall.size.y, WALL_HEIGHT), "%s is %.2f m high" % [wall_name, wall.size.y])
		_expect(failures, is_equal_approx(minf(wall.size.x, wall.size.z), WALL_THICKNESS), "%s is %.2f m thick" % [wall_name, minf(wall.size.x, wall.size.z)])

	# Doorway: 1.6 m wide, 2.4 m high, in the wall at each marker.
	for point: Marker3D in [entrance, exit_point]:
		var label := point.name
		for sideways: float in [0.0, 0.7, -0.7]:
			_expect(failures, not _ray_hits(room, point, Vector3(sideways, RAY_HEIGHT, 1.0), Vector3(sideways, RAY_HEIGHT, -1.0)), "%s: a ray %.1f m off the middle hits the wall" % [label, sideways])
		for sideways: float in [0.9, -0.9]:
			_expect(failures, _ray_hits(room, point, Vector3(sideways, RAY_HEIGHT, 1.0), Vector3(sideways, RAY_HEIGHT, -1.0)), "%s: a ray %.1f m off the middle passes the wall" % [label, sideways])
		_expect(failures, not _ray_hits(room, point, Vector3(0.0, 2.3, 1.0), Vector3(0.0, 2.3, -1.0)), "%s: the doorway is lower than 2.3 m" % label)
		_expect(failures, _ray_hits(room, point, Vector3(0.0, 2.5, 1.0), Vector3(0.0, 2.5, -1.0)), "%s: the doorway is higher than 2.5 m" % label)
	root.remove_child(room)
	room.free()
	return failures

## Casts a ray in a marker's own space (x sideways, y up, -z the way through the wall).
func _ray_hits(room: Node3D, point: Marker3D, from_local: Vector3, to_local: Vector3) -> bool:
	var query := PhysicsRayQueryParameters3D.create(point.global_transform * from_local, point.global_transform * to_local)
	return not room.get_world_3d().direct_space_state.intersect_ray(query).is_empty()

func test_snapping(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step)
	var rooms := _rooms_of(main.get_node("Level"))
	_expect(failures, rooms.size() >= 1, "%d rooms" % rooms.size())
	for i in range(rooms.size() - 1):
		var exit_point: Transform3D = (rooms[i].get("exit") as Marker3D).global_transform
		var entrance: Transform3D = (rooms[i + 1].get("entrance") as Marker3D).global_transform
		_expect(failures, exit_point.origin.distance_to(entrance.origin) < 1e-4, "room %d Entrance is %.5f m from room %d Exit" % [i + 1, exit_point.origin.distance_to(entrance.origin), i])
		_expect(failures, exit_point.basis.is_equal_approx(entrance.basis), "room %d Entrance faces another way than room %d Exit" % [i + 1, i])
	await _unload(main)
	return failures

## All rooms of a level in order: its children that have an Entrance.
func _rooms_of(level: Node3D) -> Array[Node3D]:
	var rooms: Array[Node3D] = []
	for child in level.get_children():
		if child is Node3D and child.get("entrance") != null and not child.is_queued_for_deletion():
			rooms.append(child)
	return rooms

#endregion

#region The goal room module

func test_goal_room(step: String) -> Array[String]:
	var failures: Array[String] = []
	var room := (load("res://steps/%s/room_goal.tscn" % step) as PackedScene).instantiate() as Node3D
	var player := (load("res://steps/%s/player.tscn" % step) as PackedScene).instantiate()
	var capsule := (player.get_node("CollisionShape3D") as CollisionShape3D).shape as CapsuleShape3D
	player.free()
	root.add_child(room)
	await _wait_physics(5)

	# Entrance only: no Exit marker, no doorway in the far wall.
	_expect(failures, room.get_node_or_null("Exit") == null, "the goal room has an Exit")
	_expect(failures, (room.get_node("Shell/WallFar") as Node).get_child_count() == 0, "the far wall of the goal room has a doorway")
	var entrance: Marker3D = room.get_node("Entrance")
	_expect(failures, entrance.transform.origin.is_equal_approx(Vector3(0.0, 0.0, 7.0)) and entrance.transform.basis.is_equal_approx(Basis.IDENTITY), "Entrance is at %s, expected (0, 0, 7) unrotated" % entrance.transform)
	var floor_box := room.get_node("Shell/Floor") as CSGBox3D
	_expect(failures, Vector2(floor_box.size.x, floor_box.size.z).is_equal_approx(Vector2(10.0, 14.0)), "the floor is %.1f x %.1f m, expected 10 x 14" % [floor_box.size.x, floor_box.size.z])
	var inside_shape := room.get_node("Inside/CollisionShape3D") as CollisionShape3D
	_expect(failures, (inside_shape.shape as BoxShape3D).size.is_equal_approx(Vector3(10.0, 3.0, 14.0)), "the Inside box is %s" % (inside_shape.shape as BoxShape3D).size)
	_expect(failures, room.get_node_or_null("Ceiling") != null and room.get_node_or_null("RoomLight") != null and room.get_node_or_null("Fixture") != null, "ceiling, room light or fixture missing")
	# Open at the entrance: a ray through the doorway passes; the far wall is solid everywhere.
	_expect(failures, not _ray_hits(room, entrance, Vector3(0.0, RAY_HEIGHT, 1.0), Vector3(0.0, RAY_HEIGHT, -1.0)), "the entrance doorway is closed")
	var space := room.get_world_3d().direct_space_state
	for sideways: float in [0.0, 1.0, -2.5, 3.0]:
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(sideways, RAY_HEIGHT, -5.0), Vector3(sideways, RAY_HEIGHT, -8.0)))
		_expect(failures, not hit.is_empty(), "a ray through the far wall at x = %.1f passes: there is a doorway" % sideways)

	# The pad: 3 x 3, raised a little (a step the capsule climbs), the gold accent, from the shared materials.
	var pad := room.get_node("Shell/Pad") as CSGBox3D
	_expect(failures, is_equal_approx(pad.size.x, 3.0) and is_equal_approx(pad.size.z, 3.0), "the pad is %.1f x %.1f m, expected 3 x 3" % [pad.size.x, pad.size.z])
	var pad_top := pad.position.y + pad.size.y / 2.0
	_expect(failures, pad.size.y >= 0.05 and pad.size.y <= 0.15 and is_equal_approx(pad_top, pad.size.y), "the pad is %.2f m high (top at %.2f), expected a low step standing on the floor" % [pad.size.y, pad_top])
	_expect(failures, pad.material != null and pad.material.resource_path == MATERIAL_DIR + "goal.tres", "the pad does not use goal.tres")
	var pad_box := AABB(pad.position - pad.size / 2.0, pad.size)
	_expect(failures, AABB(Vector3(-5.0, 0.0, -7.0), Vector3(10.0, 0.2, 14.0)).encloses(pad_box), "the pad does not lie inside the room")
	_expect(failures, pad_box.position.z + pad_box.size.z < -1.0, "the pad is not at the far end, away from the entrance")
	var down := space.intersect_ray(PhysicsRayQueryParameters3D.create(pad.global_position + Vector3(0.0, 1.0, 0.0), pad.global_position + Vector3(0.0, -1.0, 0.0)))
	_expect(failures, not down.is_empty() and absf((down["position"] as Vector3).y - pad_top) < 0.01, "a ray down onto the pad does not hit its top")
	var up := space.intersect_ray(PhysicsRayQueryParameters3D.create(pad.global_position + Vector3(0.0, 1.0, 0.0), pad.global_position + Vector3(0.0, 3.5, 0.0)))
	_expect(failures, not up.is_empty() and absf((up["position"] as Vector3).y - WALL_HEIGHT) < 0.01, "a ray up from the pad does not hit the ceiling")

	# The trigger: the player layer only, over the pad, small enough that the whole capsule is on the pad when it fires.
	var goal_pad := room.get_node("GoalPad") as Area3D
	_expect(failures, goal_pad.collision_layer == 0 and goal_pad.collision_mask == 2, "GoalPad: layer %d mask %d, expected 0 and 2 (the player layer)" % [goal_pad.collision_layer, goal_pad.collision_mask])
	_expect(failures, goal_pad.global_position.is_equal_approx(Vector3(pad.position.x, 0.0, pad.position.z)), "GoalPad is at %s, not at the middle of the pad" % goal_pad.global_position)
	var trigger := goal_pad.get_node("CollisionShape3D") as CollisionShape3D
	var trigger_box := trigger.shape as BoxShape3D
	_expect(failures, trigger_box != null and trigger.position.y - trigger_box.size.y / 2.0 < capsule.height and trigger.position.y + trigger_box.size.y / 2.0 > pad_top, "the trigger does not reach the player's body")
	if trigger_box != null:
		_expect(failures, trigger_box.size.x / 2.0 + capsule.radius <= pad.size.x / 2.0 + 0.001 and trigger_box.size.z / 2.0 + capsule.radius <= pad.size.z / 2.0 + 0.001, "the trigger fires before the capsule is on the pad (half %.2f + radius %.2f > pad half %.2f)" % [trigger_box.size.x / 2.0, capsule.radius, pad.size.x / 2.0])

	# Its own small warm light and a visible fixture over the pad, on the ceiling layer like the room's lamp.
	var light := room.get_node("PadLight") as OmniLight3D
	var fixture := room.get_node("PadFixture") as MeshInstance3D
	var block := fixture.mesh as BoxMesh
	_expect(failures, not light.shadow_enabled, "PadLight casts shadows")
	_expect(failures, light.light_color.r >= light.light_color.g and light.light_color.g >= light.light_color.b and light.light_color.b < 0.95, "PadLight is not warm")
	_expect(failures, light.omni_range < (room.get_node("RoomLight") as OmniLight3D).omni_range and light.omni_range >= Vector3(1.5, 0.0, 1.5).length() and light.omni_range <= 6.0, "PadLight range %.1f is not a small light that covers the pad" % light.omni_range)
	_expect(failures, Vector2(light.position.x - pad.position.x, light.position.z - pad.position.z).length() < 0.01 and light.position.y > 2.2 and light.position.y < WALL_HEIGHT, "PadLight is not over the pad near the ceiling (%s)" % light.position)
	_expect(failures, fixture.layers == CEILING_LAYER, "PadFixture is on layers %d, expected only layer 2" % fixture.layers)
	_expect(failures, block.material != null and block.material.resource_path == MATERIAL_DIR + "fixture.tres", "PadFixture does not use fixture.tres")
	_expect(failures, is_equal_approx(fixture.position.y + block.size.y / 2.0, WALL_HEIGHT) and Vector2(fixture.position.x - light.position.x, fixture.position.z - light.position.z).length() < 0.01, "PadFixture does not hang under the ceiling above the PadLight")
	_expect(failures, block.size.x <= 0.5 and block.size.z <= 0.5, "PadFixture is %.1f x %.1f m: a small light gets a small block" % [block.size.x, block.size.z])
	root.remove_child(room)
	room.free()
	return failures

#endregion

#region Player

func test_walk(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step)
	var player: CharacterBody3D = main.get_node("Level").player
	var start := player.global_position
	_expect(failures, player.is_on_floor(), "player is not on the floor at the start")
	_expect(failures, start.distance_to(Vector3(0.0, 0.0, 3.5)) < 0.05, "player starts at %s, expected 1.5 m inside room 0 at (0, 0, 3.5)" % start)
	_expect(failures, (-player.global_basis.z).is_equal_approx(Vector3.FORWARD), "player does not face the way the chain starts")

	# 45 frames at 5 m/s: 3.75 m, still short of the first door's trigger.
	Input.action_press("move_forward")
	await _wait_physics(45)
	Input.action_release("move_forward")
	var moved := player.global_position - start
	_expect(failures, moved.dot(-player.global_basis.z) > 3.5, "moved only %.2f m forward" % moved.dot(-player.global_basis.z))
	_expect(failures, absf(moved.x) < 0.1, "drifted %.2f m sideways" % moved.x)
	_expect(failures, absf(player.global_position.y) < 0.05, "left the floor (y = %.3f)" % player.global_position.y)

	# Relative to the facing: turned right by a quarter, forward now goes along +x.
	player.rotation.y = -PI / 2.0
	var before := player.global_position
	Input.action_press("move_forward")
	await _wait_physics(30)
	Input.action_release("move_forward")
	var turned := player.global_position - before
	_expect(failures, turned.x > 2.0 and absf(turned.z) < 0.1, "facing right, forward moved %s" % turned)
	await _unload(main)
	return failures

func test_jump(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step)
	var player: CharacterBody3D = main.get_node("Level").player
	var camera: Camera3D = player.get_node("Head/Camera3D")
	var capsule := (player.get_node("CollisionShape3D") as CollisionShape3D).shape as CapsuleShape3D
	var ceiling_bottom := _ceiling_bottom(_rooms_of(main.get_node("Level"))[0])
	Input.action_press("jump")
	await _wait_physics(2)
	Input.action_release("jump")
	var highest := 0.0
	var highest_eye := 0.0
	for i in 30:
		await physics_frame
		highest = maxf(highest, player.global_position.y)
		highest_eye = maxf(highest_eye, camera.global_position.y)
	_expect(failures, highest > 0.8 and highest < 1.2, "highest point %.2f m, expected about 1.03" % highest)
	_expect(failures, highest + capsule.height < ceiling_bottom, "the head reaches %.2f m at the top of the jump, the ceiling is at %.2f m" % [highest + capsule.height, ceiling_bottom])
	_expect(failures, highest_eye < ceiling_bottom - 0.2, "the eye reaches %.2f m at the top of the jump, the ceiling is at %.2f m (0.2 m for the near plane)" % [highest_eye, ceiling_bottom])
	await _wait_physics(60)
	_expect(failures, player.is_on_floor(), "player did not land")
	_expect(failures, absf(player.global_position.y) < 0.05, "landed at y = %.3f" % player.global_position.y)
	await _unload(main)
	return failures

func test_sealed_entrance(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step)
	var player: CharacterBody3D = main.get_node("Level").player
	player.rotation.y = PI # look at the entrance wall
	Input.action_press("move_forward")
	await _wait_physics(90)
	Input.action_release("move_forward")
	# The wall's inner face is at z = 4.8 (0.2 m thick, flush with the footprint) and the capsule radius is 0.4 m.
	_expect(failures, player.global_position.z > 4.2 and player.global_position.z < 4.55, "stopped at z = %.2f, expected about 4.4" % player.global_position.z)
	_expect(failures, absf(player.global_position.y) < 0.05, "left the floor (y = %.3f)" % player.global_position.y)
	await _unload(main)
	return failures

func test_stick_look(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step)
	var player: CharacterBody3D = main.get_node("Level").player
	var head: Node3D = player.get_node("Head")

	# 3 rad/s for one second turns the body by about 3 rad (right is negative yaw).
	Input.action_press("look_right")
	await _wait_physics(60)
	Input.action_release("look_right")
	var turned := wrapf(-player.rotation.y, -PI, PI)
	_expect(failures, absf(turned - 3.0) < 0.15, "the stick turned the body by %.2f rad in 1 s" % turned)
	_expect(failures, is_zero_approx(head.rotation.x), "yaw moved the head pitch")

	Input.action_press("look_down")
	await _wait_physics(60)
	Input.action_release("look_down")
	_expect(failures, is_equal_approx(head.rotation.x, -deg_to_rad(89.0)), "looking down: pitch %.1f deg" % rad_to_deg(head.rotation.x))
	Input.action_press("look_up")
	await _wait_physics(120)
	Input.action_release("look_up")
	_expect(failures, is_equal_approx(head.rotation.x, deg_to_rad(89.0)), "looking up: pitch %.1f deg" % rad_to_deg(head.rotation.x))
	_expect(failures, is_zero_approx(player.rotation.x) and is_zero_approx(player.rotation.z), "pitch tilted the body")
	await _unload(main)
	return failures

func test_mouse_math(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step)
	var player: CharacterBody3D = main.get_node("Level").player
	var head: Node3D = player.get_node("Head")
	var sensitivity: float = player.get("mouse_sensitivity")
	_expect(failures, is_equal_approx(sensitivity, 0.002), "sensitivity is %f rad per pixel" % sensitivity)
	var yaw := player.rotation.y
	player.call("rotate_view", Vector2(100.0, 0.0) * sensitivity)
	_expect(failures, is_equal_approx(player.rotation.y - yaw, -0.2), "100 px right turned the body by %.3f rad, expected -0.2" % (player.rotation.y - yaw))
	_expect(failures, is_zero_approx(head.rotation.x), "yaw moved the head pitch")
	player.call("rotate_view", Vector2(0.0, 100000.0) * sensitivity)
	_expect(failures, is_equal_approx(head.rotation.x, -deg_to_rad(89.0)), "mouse down: pitch %.1f deg" % rad_to_deg(head.rotation.x))
	player.call("rotate_view", Vector2(0.0, -200000.0) * sensitivity)
	_expect(failures, is_equal_approx(head.rotation.x, deg_to_rad(89.0)), "mouse up: pitch %.1f deg" % rad_to_deg(head.rotation.x))
	_expect(failures, is_zero_approx(player.rotation.x), "pitch tilted the body")
	await _unload(main)
	return failures

#endregion

#region Doors

func test_door(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step)
	var level: Node3D = main.get_node("Level")
	var player: CharacterBody3D = level.player
	var room: Node3D = level.rooms[0]
	var door: Node3D = room.get("door")
	var door_point := (room.get("exit") as Marker3D).global_transform
	var opened_at: Array[float] = []
	door.connect("opened", func() -> void: opened_at.append(_depth(player, door_point)))

	var slab := door.get_node("Hinge/MeshInstance3D") as MeshInstance3D
	var slab_material := (slab.mesh as BoxMesh).material
	_expect(failures, slab_material != null and slab_material.resource_path == MATERIAL_DIR + "door.tres", "the door panel is not the accent material res://materials/door.tres")
	_expect(failures, not door.get("is_open"), "the door starts open")
	_expect(failures, _door_blocks(level, door_point), "the closed door lets a ray pass")
	await _wait_physics(10)
	_expect(failures, not door.get("is_open"), "the door opened by itself")

	# Walk up to it: it opens while the player is still a few metres away.
	Input.action_press("move_forward")
	for i in 150:
		await physics_frame
		if door.get("is_open"):
			break
	Input.action_release("move_forward")
	_expect(failures, door.get("is_open"), "the door did not open on approach")
	_expect(failures, opened_at.size() == 1, "`opened` was emitted %d times" % opened_at.size())
	if opened_at.size() == 1:
		_expect(failures, opened_at[0] < -2.5 and opened_at[0] > -4.2, "the door opened when the player was %.2f m away" % -opened_at[0])

	# Open: the hinge is turned 90 degrees and a ray passes through the doorway.
	await _wait_physics(40)
	var hinge: Node3D = door.get("hinge")
	_expect(failures, absf(hinge.rotation.y - (-PI / 2.0)) < 0.02, "the open door is at %.1f deg" % rad_to_deg(hinge.rotation.y))
	_expect(failures, not _door_blocks(level, door_point), "the open doorway blocks a ray")
	_expect(failures, not _door_blocks(level, door_point, 0.5), "the open doorway blocks a ray 0.5 m off the middle")

	# Closed again: it blocks the ray and the player.
	door.call("close")
	await _wait_physics(40)
	_expect(failures, not door.get("is_open"), "the door is still open after close()")
	_expect(failures, absf(hinge.rotation.y) < 0.02, "the closed door is at %.1f deg" % rad_to_deg(hinge.rotation.y))
	_expect(failures, _door_blocks(level, door_point), "the closed door lets a ray pass")
	Input.action_press("move_forward")
	await _wait_physics(90)
	Input.action_release("move_forward")
	var depth := _depth(player, door_point)
	_expect(failures, depth < -0.3 and depth > -0.65, "walking into the closed door stopped %.2f m before it" % -depth)
	await _unload(main)
	return failures

## True if a ray through the doorway at the exit is stopped by the door. sideways moves it off the middle.
func _door_blocks(level: Node3D, door_point: Transform3D, sideways := -0.3) -> bool:
	var query := PhysicsRayQueryParameters3D.create(door_point * Vector3(sideways, RAY_HEIGHT, 1.0), door_point * Vector3(sideways, RAY_HEIGHT, -2.0))
	query.exclude = [(level.player as CollisionObject3D).get_rid()]
	return not level.get_world_3d().direct_space_state.intersect_ray(query).is_empty()

## How far the player is in front of the exit plane; negative before it.
func _depth(player: Node3D, door_point: Transform3D) -> float:
	return (player.global_position - door_point.origin).dot(-door_point.basis.z)

func test_door_waits_for_the_swing(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step)
	var level: Node3D = main.get_node("Level")
	var player: CharacterBody3D = level.player
	var room: Node3D = level.rooms[0]
	var door: Node3D = room.get("door")
	var door_point := (room.get("exit") as Marker3D).global_transform
	var hinge: Node3D = door.get("hinge")

	# Walk into the doorway, the door opening on the way.
	Input.action_press("move_forward")
	for i in 240:
		await physics_frame
		if _depth(player, door_point) > 0.5:
			break
	Input.action_release("move_forward")
	_expect(failures, _depth(player, door_point) > 0.5, "the player did not get through the doorway")
	await _wait_physics(20)

	# Asked to close while the player is in the swing: nothing happens.
	door.call("close")
	await _wait_physics(45)
	_expect(failures, door.get("is_open") and absf(hinge.rotation.y + PI / 2.0) < 0.02, "the door closed on the player (hinge at %.1f deg)" % rad_to_deg(hinge.rotation.y))

	# Out of the swing: it closes, and the player was not touched.
	Input.action_press("move_forward")
	await _wait_physics(60)
	Input.action_release("move_forward")
	var before := player.global_position
	await _wait_physics(60)
	_expect(failures, not door.get("is_open") and absf(hinge.rotation.y) < 0.02, "the door did not close after the player left (hinge at %.1f deg)" % rad_to_deg(hinge.rotation.y))
	_expect(failures, player.global_position.distance_to(before) < 0.01, "the closing door moved the player by %.3f m" % player.global_position.distance_to(before))
	await _unload(main)
	return failures

## The open leaf stands in the next room, 1.6 m long, right where the way leads on. A player pressed against its face who slides
## past its free end must keep moving. On GodotPhysics3D a capsule whose axis stood a tenth of a millimetre past the end of the
## leaf's box was held in place for good (the box has a blind spot at its end edge, the one contact that is still reported is
## the floor's, and every move has zero travel). The projects run Jolt, which has no such blind spot; this guards the setting.
func test_open_leaf_end(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step)
	var level: Node3D = main.get_node("Level")
	var player: CharacterBody3D = level.player
	var door: Node3D = level.rooms[0].get("door")
	door.call("open")
	await _wait_physics(45) # the swing takes half a second
	door.set_physics_process(false) # the leaf stays open, whatever the probes do
	var hinge: Node3D = door.get("hinge")
	_expect(failures, absf(hinge.rotation.y + PI / 2.0) < 0.02, "the leaf is not open (%.1f deg)" % rad_to_deg(hinge.rotation.y))
	var radius := ((player.get_node("CollisionShape3D") as CollisionShape3D).shape as CapsuleShape3D).radius
	var face_x := 0.8 - 0.05 # the door's frame: the hinge sits at x = 0.8, the leaf is 0.1 thick and runs 1.6 m into the room (-z)
	var end_z := -1.6
	var yaw := atan2(-0.8, 0.6) # facing +x and on into the room, as the autopilot does when the exit is on the right
	var held: Array[String] = []
	var probes := 0
	for beyond_mm: float in [0.0, 0.05, 0.1]: # how far the capsule's axis stands past the end of the leaf
		for apart_mm: float in [0.0, 0.1, 0.2]: # how far its side is from the face
			var spot := Vector3(face_x - radius - apart_mm / 1000.0, 0.0, end_z - beyond_mm / 1000.0)
			player.global_transform = door.global_transform * Transform3D(Basis(Vector3.UP, yaw), spot)
			player.velocity = Vector3.ZERO
			await _wait_physics(2)
			var before := player.global_position
			Input.action_press("move_forward")
			await _wait_physics(10)
			Input.action_release("move_forward")
			probes += 1
			var moved := Vector2(player.global_position.x - before.x, player.global_position.z - before.z).length()
			if moved < 0.3:
				held.append("%.2f mm past the end, %.1f mm from the face: moved %.4f m" % [beyond_mm, apart_mm, moved])
	_expect(failures, held.is_empty(), "the player was held in place in %d of %d probes: %s" % [held.size(), probes, held.slice(0, 3)])
	await _unload(main)
	return failures

#endregion

#region Streaming with the real player

## Per-frame checks while the autopilot walks through the chain.
class Watcher extends RefCounted:
	var level: Node3D
	var pilot: RefCounted
	var failures: Array[String] = []
	var frame := 0
	var max_live := 0
	var max_step := 0.0
	var passed := {} ## Door index -> true once the player crossed its plane.
	var clear_since := {} ## Door index -> frame when the player was clear of the swing.
	var verified_closed := {} ## Door index -> true once checked closed and blocking.
	var checked_current := 0
	var current_since := 0 ## Frame when the player entered the room the player is in.
	var _last_position := Vector3.ZERO

	func _init(watched_level: Node3D, watched_pilot: RefCounted) -> void:
		level = watched_level
		pilot = watched_pilot
		_last_position = (watched_level.player as Node3D).global_position

	func fail(message: String) -> void:
		if failures.size() < 12:
			failures.append("frame %d: %s" % [frame, message])

	func check() -> void:
		frame += 1
		var player: CharacterBody3D = level.player
		var rooms: Dictionary = level.rooms
		var plans: Array = level.chain.plans ## Plans of the step under test, a class of its own.
		max_live = maxi(max_live, rooms.size())
		if rooms.size() > 3:
			fail("%d live rooms" % rooms.size())
		if plans.size() > int(level.current) + 2:
			fail("%d plans made while the player is in room %d" % [plans.size(), level.current])

		# Never pushed through a wall: always inside a live room, on the floor, no jumps in position.
		var inside := false
		for index: int in rooms.keys():
			if plans[index].bounds.grow(0.2).has_point(player.global_position):
				inside = true
		if not inside:
			fail("player at %s is outside every live room" % player.global_position)
		if player.global_position.y < -0.1 or player.global_position.y > 0.3:
			fail("player at height %.2f" % player.global_position.y)
		var step := player.global_position.distance_to(_last_position)
		max_step = maxf(max_step, step)
		if step > 0.2:
			fail("the player moved %.2f m in one physics frame, from %s to %s" % [step, _last_position, player.global_position])
		_last_position = player.global_position

		# The next room exists, and the door is open, before the player passes the door.
		var target: int = pilot.door_index
		if pilot.depth_at(target) >= 0.0 and not passed.has(target):
			passed[target] = true
			if not rooms.has(target + 1):
				fail("room %d did not exist when the player passed door %d" % [target + 1, target])
			elif not rooms[target].door.is_open:
				fail("door %d was closed when the player passed it" % target)

		# The door behind closes once the player is clear of the swing, and then it blocks.
		for index: int in rooms.keys():
			if index >= level.current or verified_closed.has(index):
				continue
			var depth: float = pilot.depth_at(index)
			if depth > 2.6 and not clear_since.has(index):
				clear_since[index] = frame
			if clear_since.has(index) and frame - int(clear_since[index]) > 45:
				verified_closed[index] = true
				var door: Node3D = rooms[index].door
				var door_point := (rooms[index].exit as Marker3D).global_transform
				if door.is_open or absf(door.hinge.rotation.y) > 0.02:
					fail("door %d is still open %d frames after the player cleared it" % [index, frame - int(clear_since[index])])
				var query := PhysicsRayQueryParameters3D.create(door_point * Vector3(-0.3, 1.2, -1.0), door_point * Vector3(-0.3, 1.2, 1.0))
				query.exclude = [player.get_rid()]
				if level.get_world_3d().direct_space_state.intersect_ray(query).is_empty():
					fail("door %d is closed but a ray passes it" % index)

		# Rooms behind the previous one are gone: from the dictionary, and, three frames on, from the tree.
		if level.current != checked_current:
			checked_current = level.current
			current_since = frame
		for index: int in rooms.keys():
			if index < level.current - 1:
				fail("room %d still exists while the player is in room %d" % [index, level.current])
		if frame - current_since == 3:
			var in_tree := 0
			for child in level.get_children():
				if child.get("entrance") != null:
					in_tree += 1
			if in_tree != rooms.size():
				fail("%d room nodes in the tree for %d live rooms" % [in_tree, rooms.size()])

func test_streaming(step: String) -> Array[String]:
	var main := await _load_step(step)
	var level: Node3D = main.get_node("Level")
	var pilot := Autopilot.new(level)
	var watcher := Watcher.new(level, pilot)
	_fast_forward(true)

	_expect(watcher.failures, level.rooms.size() == 1, "%d rooms before the player moved" % level.rooms.size())
	var arrived := await _walk(level, pilot, STREAM_ROOMS, 0, watcher.check)
	_expect(watcher.failures, arrived, "the player did not reach room %d (stuck in room %d after %d frames)" % [STREAM_ROOMS, level.current, watcher.frame])
	# Keep walking so the last door can close behind the player.
	var frames_left := [150]
	await _drive(func() -> bool:
		pilot.physics_step()
		watcher.check()
		frames_left[0] -= 1
		return frames_left[0] <= 0)
	pilot.release()
	_fast_forward(false)

	_expect(watcher.failures, watcher.max_live == 3, "at most %d rooms were live at once, expected 3" % watcher.max_live)
	_expect(watcher.failures, watcher.max_step < 0.2, "the player moved %.2f m in one physics frame" % watcher.max_step)
	_expect(watcher.failures, watcher.passed.size() >= STREAM_ROOMS - 1, "the player passed only %d doors" % watcher.passed.size())
	_expect(watcher.failures, watcher.verified_closed.size() >= STREAM_ROOMS - 2, "only %d doors were seen closing behind the player" % watcher.verified_closed.size())
	var live: Array[Node3D] = _rooms_of(level)
	_expect(watcher.failures, live.size() == level.rooms.size() and live.size() <= 3, "%d room nodes in the tree for %d live rooms" % [live.size(), level.rooms.size()])
	for i in range(live.size() - 1):
		var exit_point: Transform3D = (live[i].get("exit") as Marker3D).global_transform
		var entrance: Transform3D = (live[i + 1].get("entrance") as Marker3D).global_transform
		_expect(watcher.failures, exit_point.origin.distance_to(entrance.origin) < 1e-4 and exit_point.basis.is_equal_approx(entrance.basis), "live rooms %d and %d are not snapped" % [i, i + 1])
	# Walking back builds nothing: the door behind is shut and the plans stay as they are.
	var plan_count: int = level.chain.plans.size()
	var seed_plans := _level_plans(step, level.chain_seed, plan_count, _goal_of(level))
	_expect(watcher.failures, _same_plans(level.chain.plans, seed_plans), "the streamed plans differ from the pure-data chain")
	Input.action_press("move_back")
	await _wait_physics(120)
	Input.action_release("move_back")
	_expect(watcher.failures, level.chain.plans.size() == plan_count, "walking back made %d new plans" % (level.chain.plans.size() - plan_count))
	await _unload(main)
	return watcher.failures

## The pure-data chain of a step: tutorial 01's before the goal room, with it from step 2 on.
func _level_plans(step: String, chain_seed: int, count: int, goal_room: int) -> Array:
	if step == "step_00_start" or step == "step_01_room_counter":
		return _plans(OldChain, chain_seed, count, false)
	var chain: RefCounted = Chain.new(chain_seed, goal_room)
	for i in count:
		chain.next_plan()
	return chain.plans

## The level's goal room (tutorial 01's steps have none: 20 is only passed on).
func _goal_of(level: Node3D) -> int:
	return level.get("goal_room") if level.get("goal_room") != null else 20

## Calls its callback once per physics tick, before the player's own tick.
class Driver extends Node:
	signal finished
	var tick: Callable

	func _physics_process(_delta: float) -> void:
		if tick.is_valid() and tick.call():
			tick = Callable()
			finished.emit()

## Runs tick once per physics tick until it returns true. (With Engine.time_scale above 1
## several ticks happen per frame, and `await physics_frame` would only see one of them.)
func _drive(tick: Callable) -> void:
	var driver := Driver.new()
	driver.process_priority = -100
	driver.tick = tick
	root.add_child(driver)
	await driver.finished
	root.remove_child(driver)
	driver.queue_free()

## Walks until the player is in room `goal`. dawdle: ticks of standing still at the start and at every new door.
func _walk(level: Node3D, pilot: RefCounted, goal: int, dawdle: int, on_tick: Callable) -> bool:
	var state := {"budget": 1500 * goal, "wait": dawdle, "target": pilot.door_index}
	await _drive(func() -> bool:
		if state["wait"] > 0:
			state["wait"] -= 1
		else:
			pilot.physics_step()
			if pilot.door_index != state["target"]:
				state["target"] = pilot.door_index
				state["wait"] = dawdle
				pilot.release()
		if on_tick.is_valid():
			on_tick.call()
		state["budget"] -= 1
		return level.current >= goal or state["budget"] <= 0)
	pilot.release()
	return level.current >= goal

## Walks until the run is FINISHED (the player stands on the goal pad). dawdle: ticks of standing
## still at every new door after the first, which makes the run slower. Returns true if it finished.
func _walk_to_finish(level: Node3D, pilot: RefCounted, dawdle := 0, budget := 40000) -> bool:
	var state := {"budget": budget, "wait": 0, "target": pilot.door_index}
	await _drive(func() -> bool:
		if state["wait"] > 0:
			state["wait"] -= 1
		else:
			pilot.physics_step()
			if pilot.door_index != state["target"]:
				state["target"] = pilot.door_index
				state["wait"] = dawdle
				pilot.release()
		state["budget"] -= 1
		return level.state == STATE_FINISHED or state["budget"] <= 0)
	pilot.release()
	return level.state == STATE_FINISHED

func test_timing_independence(step: String) -> Array[String]:
	var failures: Array[String] = []
	_fast_forward(true)
	for dawdle: int in [0, 30, 200]:
		var main := await _load_step(step)
		var level: Node3D = main.get_node("Level")
		var pilot := Autopilot.new(level)
		var arrived := await _walk(level, pilot, 7, dawdle, Callable())
		_expect(failures, arrived, "dawdle %d: did not reach room 7" % dawdle)
		var made: Array = level.chain.plans
		_expect(failures, made.size() >= 8, "dawdle %d: only %d plans" % [dawdle, made.size()])
		_expect(failures, _same_plans(made, _level_plans(step, level.chain_seed, made.size(), _goal_of(level))), "dawdle %d: the streamed plans differ from the pure-data chain" % dawdle)
		await _unload(main)
	_fast_forward(false)
	return failures

#endregion

#region Debug map

func test_toggle_map(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step)
	var map: Control = main.get_node("HUD/DebugMap")
	_expect(failures, map.get_parent() is CanvasLayer, "the map is not under a CanvasLayer")
	_expect(failures, map.visible, "the map does not start visible")
	_expect(failures, map.mouse_filter == Control.MOUSE_FILTER_IGNORE, "the map takes mouse input")
	_expect(failures, map.position.is_equal_approx(Vector2(16.0, 16.0)) and map.size.is_equal_approx(Vector2(300.0, 300.0)), "the map is %s at %s, expected 300x300 at the top left" % [map.size, map.position])
	await _action("toggle_debug")
	_expect(failures, not map.visible, "Tab did not hide the map")
	await _action("toggle_debug")
	_expect(failures, map.visible, "Tab did not show the map again")
	await _unload(main)
	return failures

func test_map_reads_data_only(step: String) -> Array[String]:
	var failures: Array[String] = []
	var source := FileAccess.get_file_as_string("res://steps/%s/debug_map.gd" % step)
	for forbidden: String in ["get_node", "get_tree", "find_child", "get_children", "$", "Physics"]:
		_expect(failures, not source.contains(forbidden), "debug_map.gd uses `%s`" % forbidden)
	_expect(failures, source.contains("level.chain.plans") and source.contains("level.rooms"), "debug_map.gd does not draw the plan history")
	return failures

#endregion

#region Step 1: the room counter

func test_counter(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step)
	var level: Node3D = main.get_node("Level")
	var label: Label = main.get_node("HUD/Stats/RoomLabel")
	_expect(failures, label.text == "Room 0 / 20", "the counter reads \"%s\" at the start, expected \"Room 0 / 20\"" % label.text)
	_expect(failures, level.get("goal_room") == 20, "goal_room is %s, expected 20" % level.get("goal_room"))

	# Every room the player enters: the signal comes with the index, and the label has the new text at once.
	var entered: Array[int] = []
	var texts: Array[String] = []
	level.connect("room_entered", func(index: int) -> void:
		entered.append(index)
		texts.append(label.text))
	_fast_forward(true)
	var pilot := Autopilot.new(level)
	var arrived := await _walk(level, pilot, 4, 0, Callable())
	_fast_forward(false)
	_expect(failures, arrived, "the player did not reach room 4")
	_expect(failures, entered == [1, 2, 3, 4], "room_entered was sent for %s, expected [1, 2, 3, 4]" % [entered])
	_expect(failures, texts == ["Room 1 / 20", "Room 2 / 20", "Room 3 / 20", "Room 4 / 20"], "the counter read %s" % [texts])
	_expect(failures, label.text == "Room 4 / 20", "the counter reads \"%s\" in room 4" % label.text)

	await _unload(main)

	# Readable at 1080p and at the project's 720p, inside the screen, clear of the map, on the right.
	main = await _load_step(step)
	for screen_size: Vector2i in [Vector2i(1920, 1080), Vector2i(1280, 720)]:
		await _set_screen(screen_size)
		var stats: Control = main.get_node("HUD/Stats")
		var map: Control = main.get_node("HUD/DebugMap")
		label = main.get_node("HUD/Stats/RoomLabel")
		label.text = "Room 20 / 20" # the widest text the counter shows
		await process_frame
		var screen := Rect2(Vector2.ZERO, Vector2(screen_size))
		var where := "at %dx%d" % [screen_size.x, screen_size.y]
		_expect(failures, label.get_theme_font_size("font_size") >= 32, "the counter font is %d px, too small for 1080p" % label.get_theme_font_size("font_size"))
		_expect(failures, label.get_theme_constant("outline_size") >= 4, "the counter has no outline: it can vanish on a bright wall")
		_expect(failures, screen.encloses(stats.get_global_rect()), "%s: the counter %s is not inside the screen" % [where, stats.get_global_rect()])
		_expect(failures, stats.get_global_rect().end.x <= screen.end.x - 8.0 and stats.get_global_rect().position.y >= 8.0, "%s: the counter is closer than 8 px to the screen corner" % where)
		_expect(failures, stats.get_global_rect().position.x > screen.size.x / 2.0, "%s: the counter is not on the right" % where)
		_expect(failures, not stats.get_global_rect().intersects(map.get_global_rect()), "%s: the counter overlaps the map" % where)
		_expect(failures, label.horizontal_alignment == HORIZONTAL_ALIGNMENT_RIGHT, "the counter is not right aligned")
		_expect(failures, label.get_minimum_size().x <= stats.size.x, "\"Room 20 / 20\" needs %.0f px, the box is %.0f px wide" % [label.get_minimum_size().x, stats.size.x])
	await _unload(main)
	return failures

#endregion

#region Step 2: the goal room in the level

## Goal room 3: the autopilot walks into it and onto the pad.
func test_goal_in_level(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step, true, {"goal_room": SHORT_GOAL})
	var level: Node3D = main.get_node("Level")
	var pilot := Autopilot.new(level)
	_fast_forward(true)
	var arrived := await _walk(level, pilot, SHORT_GOAL, 0, Callable())
	_expect(failures, arrived, "the player did not reach the goal room %d" % SHORT_GOAL)
	var plans: Array = level.chain.plans
	_expect(failures, plans.size() == SHORT_GOAL + 1 and plans[SHORT_GOAL].type == Chain.Type.GOAL, "%d plans, the last is type %d" % [plans.size(), plans[-1].type])
	var room: Node3D = level.rooms[SHORT_GOAL]
	_expect(failures, room.scene_file_path.ends_with("room_goal.tscn"), "room %d is %s" % [SHORT_GOAL, room.scene_file_path])
	_expect(failures, room.get("door") == null and room.get("exit") == null, "the goal room has a door or an exit")
	_expect(failures, level.rooms.size() == 2 and level.rooms.has(SHORT_GOAL - 1), "%d rooms live in the goal room" % level.rooms.size())
	_expect(failures, level.get("goal_room") == SHORT_GOAL and level.chain.goal_index == SHORT_GOAL, "goal_room %s, goal_index %d" % [level.get("goal_room"), level.chain.goal_index])
	if step != "step_02_goal_room":
		_expect(failures, room.get("goal_pad") != null and room.get("goal_pad") == room.get_node("GoalPad"), "the room does not point at its goal pad")

	# On: walk onto the pad. The player steps up onto it and stands inside its edges.
	var pad := room.get_node("GoalPad") as Node3D
	var player: CharacterBody3D = level.player
	var budget := [1200]
	await _drive(func() -> bool:
		pilot.physics_step()
		budget[0] -= 1
		var to_pad := Vector2(player.global_position.x - pad.global_position.x, player.global_position.z - pad.global_position.z)
		return to_pad.length() < 0.4 or level.get("state") == STATE_FINISHED or budget[0] <= 0)
	pilot.release()
	await _wait_physics(10)
	_fast_forward(false)
	var on_pad := Vector2(player.global_position.x - pad.global_position.x, player.global_position.z - pad.global_position.z).abs()
	_expect(failures, on_pad.x < 1.5 and on_pad.y < 1.5, "the player is %s from the middle of the pad" % on_pad)
	_expect(failures, absf(player.global_position.y - 0.12) < 0.02, "the player stands at y = %.3f, the pad top is 0.12" % player.global_position.y)
	await _unload(main)
	return failures

#endregion

#region Step 3: game states

func test_state_enum() -> Array[String]:
	var failures: Array[String] = []
	for step in _steps_from("step_03_game_states"):
		var constants := (load("res://steps/%s/level.gd" % step) as GDScript).get_script_constant_map()
		var states: Dictionary = constants.get("State", {})
		_expect(failures, states.get("READY") == STATE_READY and states.get("RUNNING") == STATE_RUNNING and states.get("FINISHED") == STATE_FINISHED and states.size() == 3, "%s: State is %s" % [step, states])
	return failures

func test_states(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step, true, {"goal_room": SHORT_GOAL})
	var level: Node3D = main.get_node("Level")
	var player: CharacterBody3D = level.player
	var changes: Array[int] = []
	level.connect("state_changed", func(new_state: int) -> void: changes.append(new_state))
	var door: Node3D = level.rooms[0].get("door")
	var state_when_opened: Array[int] = []
	door.connect("opened", func() -> void: state_when_opened.append(level.state))

	# READY in room 0, also while the player walks towards the door.
	_expect(failures, level.state == STATE_READY, "state %d at the start, expected READY" % level.state)
	Input.action_press("move_forward")
	await _wait_physics(30)
	Input.action_release("move_forward")
	_expect(failures, level.state == STATE_READY and changes.is_empty(), "walking in room 0 changed the state to %d" % level.state)

	# RUNNING the moment the first door opens.
	Input.action_press("move_forward")
	for i in 150:
		await physics_frame
		if door.get("is_open"):
			break
	Input.action_release("move_forward")
	_expect(failures, door.get("is_open") and level.state == STATE_RUNNING, "the first door is open, the state is %d" % level.state)
	_expect(failures, state_when_opened == [STATE_RUNNING], "the state was %s when `opened` reached the listeners" % [state_when_opened])
	_expect(failures, changes == [STATE_RUNNING], "state changes %s, expected [RUNNING]" % [changes])
	_expect(failures, not player.get("frozen"), "the player is frozen while running")

	# Standing on the pad before the run is on is nothing: only RUNNING can finish. (Called by hand, state READY.)
	level.set("state", STATE_READY)
	level.call("_on_goal_reached", player)
	_expect(failures, level.state == STATE_READY, "the goal pad finished a run that was not RUNNING")
	level.set("state", STATE_RUNNING)

	# FINISHED when the player steps onto the pad. The other doors on the way do not start anything again.
	_fast_forward(true)
	var pilot := Autopilot.new(level)
	var finished := await _walk_to_finish(level, pilot)
	_fast_forward(false)
	_expect(failures, finished, "the run did not finish (state %d, room %d)" % [level.state, level.current])
	_expect(failures, changes == [STATE_RUNNING, STATE_FINISHED], "state changes %s, expected [RUNNING, FINISHED]" % [changes])
	_expect(failures, level.current == SHORT_GOAL, "finished in room %d, expected %d" % [level.current, SHORT_GOAL])

	# The player stops: frozen, no velocity, and nothing a person can press moves it or turns it.
	await _wait_physics(20)
	_expect(failures, player.get("frozen") == true, "the player is not frozen after the finish")
	_expect(failures, player.velocity == Vector3.ZERO, "the player moves with %s after the finish" % player.velocity)
	var position := player.global_position
	var yaw := player.rotation.y
	var pitch := (player.get_node("Head") as Node3D).rotation.x
	for action: String in ["move_forward", "move_left", "jump", "look_right", "look_down"]:
		Input.action_press(action)
	await _wait_physics(60)
	for action: String in ["move_forward", "move_left", "jump", "look_right", "look_down"]:
		Input.action_release(action)
	_expect(failures, player.global_position.distance_to(position) < 0.001, "the player moved %.3f m after the finish" % player.global_position.distance_to(position))
	_expect(failures, player.rotation.y == yaw and (player.get_node("Head") as Node3D).rotation.x == pitch, "the view turned after the finish")
	_expect(failures, player.velocity == Vector3.ZERO, "the player has velocity %s" % player.velocity)
	_expect(failures, changes.size() == 2, "state changes %s after the finish" % [changes])

	# A player who is in the air at the finish comes down instead of hanging there.
	player.global_position.y += 1.0
	await _wait_physics(60)
	_expect(failures, player.is_on_floor() and player.global_position.y < 0.2, "the frozen player stays in the air (y = %.2f)" % player.global_position.y)

	# The panel: visible at the finish, saying "Finished!".
	var panel: Control = main.get_node("HUD/FinishPanel")
	_expect(failures, panel.visible, "the finish panel is not visible")
	_expect(failures, (main.get_node("HUD/FinishPanel/Rows/FinishTitle") as Label).text == "Finished!", "the panel says \"%s\"" % (main.get_node("HUD/FinishPanel/Rows/FinishTitle") as Label).text)
	await _unload(main)
	return failures

func test_finish_panel(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step, true, {"goal_room": SHORT_GOAL})
	var level: Node3D = main.get_node("Level")
	var panel: Control = main.get_node("HUD/FinishPanel")
	_expect(failures, not panel.visible, "the finish panel is visible before the finish")
	_expect(failures, panel.get_parent() == main.get_node("HUD") and main.get_node("HUD") is CanvasLayer, "the panel is not on the HUD layer")
	_expect(failures, panel.mouse_filter == Control.MOUSE_FILTER_IGNORE, "the panel takes mouse input")

	_fast_forward(true)
	var finished := await _walk_to_finish(level, Autopilot.new(level))
	_fast_forward(false)
	_expect(failures, finished, "the run did not finish")
	_expect(failures, panel.visible, "the panel is hidden after the finish")
	var title: Label = main.get_node("HUD/FinishPanel/Rows/FinishTitle")
	_expect(failures, title.get_theme_font_size("font_size") >= 48, "the title is %d px" % title.get_theme_font_size("font_size"))
	for screen_size: Vector2i in [Vector2i(1920, 1080), Vector2i(1280, 720)]:
		await _set_screen(screen_size)
		var screen := Vector2(screen_size)
		var centre := panel.get_global_rect().get_center()
		_expect(failures, centre.distance_to(screen / 2.0) < 2.0, "%dx%d: the panel is centred at %s, the screen centre is %s" % [screen_size.x, screen_size.y, centre, screen / 2.0])
		_expect(failures, Rect2(Vector2.ZERO, screen).encloses(panel.get_global_rect()), "%dx%d: the panel %s does not fit the screen" % [screen_size.x, screen_size.y, panel.get_global_rect()])
	await _unload(main)
	return failures

#endregion

#region Step 4: the run timer

func test_format_time() -> Array[String]:
	var failures: Array[String] = []
	var cases: Dictionary[float, String] = {
		0.0: "0:00.0",
		0.04: "0:00.0",
		0.1: "0:00.1",
		5.0: "0:05.0",
		42.37: "0:42.3",
		59.96: "0:59.9",
		60.0: "1:00.0",
		125.04: "2:05.0",
		599.99: "9:59.9",
		3600.0: "60:00.0",
	}
	for step in _steps_from("step_04_run_timer"):
		var hud := load("res://steps/%s/hud.gd" % step) as GDScript
		for seconds in cases:
			var text: String = hud.call("format_time", seconds)
			_expect(failures, text == cases[seconds], "%s: format_time(%s) is \"%s\", expected \"%s\"" % [step, seconds, text, cases[seconds]])
	return failures

func test_timer(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step, true, {"goal_room": SHORT_GOAL})
	var level: Node3D = main.get_node("Level")
	var time_label: Label = main.get_node("HUD/Stats/TimeLabel")
	_expect(failures, level.run_time == 0.0 and time_label.text == "0:00.0", "run_time %s, label \"%s\" at the start" % [level.run_time, time_label.text])
	_expect(failures, time_label.get_theme_font_size("font_size") >= 32, "the timer font is too small for 1080p")

	# READY: the clock does not move, however long the player stands there.
	await _wait_physics(60)
	_expect(failures, level.run_time == 0.0, "the clock moved to %s in READY" % level.run_time)

	# RUNNING: exactly the sum of the physics deltas, whatever the wall clock does. The driver runs before
	# the level on every tick and also stalls the real clock by 25 ms on every fifth tick.
	var door: Node3D = level.rooms[0].get("door")
	door.call("open")
	_expect(failures, level.state == STATE_RUNNING, "opening the door did not start the run")
	var ticks := {"count": 0, "sum": 0.0, "mismatch": 0, "start": 0.0, "wall_start": Time.get_ticks_msec()}
	await _drive(func() -> bool:
		# Before its own tick the level has added every delta that came before this one. (The level
		# had one tick of its own between open() and the driver's first tick: that is the start value.)
		if ticks["count"] == 0:
			ticks["start"] = level.run_time
		if absf(level.run_time - ticks["start"] - ticks["sum"]) > 1e-9:
			ticks["mismatch"] += 1
		ticks["sum"] += _tick_delta()
		ticks["count"] += 1
		if ticks["count"] % 5 == 0:
			OS.delay_msec(25)
		return ticks["count"] >= 121)
	var wall_ms := Time.get_ticks_msec() - int(ticks["wall_start"])
	_expect(failures, ticks["mismatch"] == 0, "the clock differed from the sum of the physics deltas on %d ticks" % ticks["mismatch"])
	_expect(failures, ticks["start"] <= _tick_delta() * 1.5, "the clock was already at %s when the driver started" % ticks["start"])
	_expect(failures, absf(level.run_time - ticks["start"] - 120.0 / 60.0) < 1e-6, "120 physics ticks gave %.6f s, expected 2.0" % (level.run_time - ticks["start"]))
	_expect(failures, wall_ms >= 500, "the test did not stall the wall clock (%d ms)" % wall_ms)

	# The label shows the clock.
	await _wait_physics(2)
	_expect(failures, time_label.text == str(load("res://steps/%s/hud.gd" % step).call("format_time", level.run_time)), "the label says \"%s\" for %.3f s" % [time_label.text, level.run_time])

	# The clock stops at the finish; the panel shows the final time.
	_fast_forward(true)
	var finished := await _walk_to_finish(level, Autopilot.new(level))
	_fast_forward(false)
	_expect(failures, finished, "the run did not finish")
	var at_finish: float = level.run_time
	await _wait_physics(90)
	_expect(failures, level.run_time == at_finish, "the clock kept running after the finish (%.3f to %.3f)" % [at_finish, level.run_time])
	var expected: String = load("res://steps/%s/hud.gd" % step).call("format_time", at_finish)
	_expect(failures, (main.get_node("HUD/FinishPanel/Rows/FinishTime") as Label).text == expected, "the panel shows \"%s\", expected \"%s\"" % [(main.get_node("HUD/FinishPanel/Rows/FinishTime") as Label).text, expected])
	_expect(failures, time_label.text == expected, "the corner shows \"%s\", expected \"%s\"" % [time_label.text, expected])
	await _unload(main)
	return failures

## The delta every node gets in a physics tick: the engine's tick length times the time scale.
func _tick_delta() -> float:
	return Engine.time_scale / float(Engine.physics_ticks_per_second)

#endregion

#region Restart

## Steps 0 to 4: R is tutorial 01's "regenerate", seed + 1. From step 3 on it also resets the run.
func test_regenerate_old(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step)
	var level: Node3D = main.get_node("Level")
	var player: CharacterBody3D = level.player
	_expect(failures, level.chain_seed == 42, "the default seed is %d, expected 42" % level.chain_seed)
	_expect(failures, _same_plans(level.chain.plans, _level_plans(step, 42, 1, 20)), "room 0 differs from the pure-data chain")

	# Open the first door so there is something to throw away.
	Input.action_press("move_forward")
	for i in 240:
		await physics_frame
		if level.rooms.size() == 2:
			break
	Input.action_release("move_forward")
	_expect(failures, level.rooms.size() == 2, "the first door did not build room 1")
	await _wait_physics(30)

	await _action("regenerate")
	await _wait_physics(10)
	_expect(failures, level.chain_seed == 43, "seed is %d after R, expected 43" % level.chain_seed)
	_expect(failures, _same_plans(level.chain.plans, _level_plans(step, 43, 1, 20)), "the new chain is not seed 43")
	_expect(failures, level.rooms.size() == 1 and level.rooms.has(0) and level.current == 0, "%d live rooms, current %d after R" % [level.rooms.size(), level.current])
	_expect(failures, _rooms_of(level).size() == 1, "%d room nodes in the tree after R" % _rooms_of(level).size())
	_expect(failures, player.global_position.distance_to(Vector3(0.0, 0.0, 3.5)) < 0.05, "player is at %s after R, expected the start of room 0" % player.global_position)
	_expect(failures, player.is_on_floor(), "player is not on the floor after R")
	_expect(failures, not level.rooms[0].door.is_open, "door 0 is open after R")
	if step != "step_00_start" and step != "step_01_room_counter" and step != "step_02_goal_room":
		_expect(failures, level.state == STATE_READY, "state %d after R, expected READY" % level.state)
	if step == "step_04_run_timer":
		_expect(failures, level.run_time == 0.0, "run_time %s after R" % level.run_time)
	if step != "step_00_start":
		_expect(failures, (main.get_node("HUD/Stats/RoomLabel") as Label).text == "Room 0 / 20", "the counter reads \"%s\" after R" % (main.get_node("HUD/Stats/RoomLabel") as Label).text)

	await _action("regenerate")
	await _wait_physics(10)
	_expect(failures, level.chain_seed == 44, "second R: seed is %d, expected 44" % level.chain_seed)
	_expect(failures, _rooms_of(level).size() == 1, "%d room nodes after the second R" % _rooms_of(level).size())
	await _unload(main)
	return failures

## Steps 5 and 6: R is the same seed again, N is seed + 1. Both reset everything through start().
func test_restart(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step, true, {"goal_room": SHORT_GOAL})
	var level: Node3D = main.get_node("Level")
	var player: CharacterBody3D = level.player
	var room_label: Label = main.get_node("HUD/Stats/RoomLabel")
	var time_label: Label = main.get_node("HUD/Stats/TimeLabel")
	var panel: Control = main.get_node("HUD/FinishPanel")
	_expect(failures, InputMap.has_action("next_seed"), "no next_seed action in the input map")
	var keys: Array[String] = []
	var buttons: Array[int] = []
	for event in InputMap.action_get_events("next_seed"):
		if event is InputEventKey:
			keys.append(OS.get_keycode_string((event as InputEventKey).physical_keycode))
		elif event is InputEventJoypadButton:
			buttons.append((event as InputEventJoypadButton).button_index)
	_expect(failures, keys == ["N"] and buttons == [JOY_BUTTON_RIGHT_SHOULDER], "next_seed is %s and %s, expected N and the right shoulder" % [keys, buttons])

	# A run in progress: two rooms in, the clock running.
	_fast_forward(true)
	var pilot := Autopilot.new(level)
	var arrived := await _walk(level, pilot, 2, 0, Callable())
	_fast_forward(false)
	await _wait_physics(10)
	_expect(failures, arrived and level.state == STATE_RUNNING and level.run_time > 1.5, "the run did not get going (state %d, %.1f s)" % [level.state, level.run_time])
	var first_run: Array = level.chain.plans.duplicate()

	# R: the same seed, a fresh run.
	await _action("regenerate")
	await _wait_physics(10)
	_expect(failures, level.chain_seed == 42, "seed is %d after R, expected 42" % level.chain_seed)
	failures.append_array(_fresh_run_problems(step, main, 42))
	_expect(failures, _same_plans(level.chain.plans, first_run.slice(0, 1)), "the first plan after R is not the same room 0")

	# The same seed, the same run: walk it again, the plans are the ones of the first run.
	_fast_forward(true)
	pilot = Autopilot.new(level)
	arrived = await _walk(level, pilot, 2, 0, Callable())
	_fast_forward(false)
	_expect(failures, arrived, "the second run did not reach room 2")
	var second_run: Array = level.chain.plans
	var shared := mini(first_run.size(), second_run.size())
	_expect(failures, shared >= 3 and _same_plans(first_run.slice(0, shared), second_run.slice(0, shared)), "R did not give the same rooms")

	# N: seed + 1.
	await _action("next_seed")
	await _wait_physics(10)
	_expect(failures, level.chain_seed == 43, "seed is %d after N, expected 43" % level.chain_seed)
	failures.append_array(_fresh_run_problems(step, main, 43))
	await _action("next_seed")
	await _wait_physics(10)
	_expect(failures, level.chain_seed == 44, "second N: seed is %d, expected 44" % level.chain_seed)
	failures.append_array(_fresh_run_problems(step, main, 44))
	await _action("regenerate")
	await _wait_physics(10)
	_expect(failures, level.chain_seed == 44, "R after N: seed is %d, expected 44" % level.chain_seed)

	# After a finish: R and N both give the player back.
	_fast_forward(true)
	pilot = Autopilot.new(level)
	var finished := await _walk_to_finish(level, pilot)
	_fast_forward(false)
	_expect(failures, finished and panel.visible and player.get("frozen") == true, "the run did not finish before the restart")
	await _action("regenerate")
	await _wait_physics(10)
	failures.append_array(_fresh_run_problems(step, main, 44))
	_fast_forward(true)
	finished = await _walk_to_finish(level, Autopilot.new(level))
	_fast_forward(false)
	_expect(failures, finished, "the second run did not finish")
	await _action("next_seed")
	await _wait_physics(10)
	failures.append_array(_fresh_run_problems(step, main, 45))
	# And the new run plays: input works again.
	var before := player.global_position
	Input.action_press("move_forward")
	await _wait_physics(20)
	Input.action_release("move_forward")
	_expect(failures, player.global_position.distance_to(before) > 1.0, "the player does not move after the restart")
	_expect(failures, room_label.text == "Room 0 / %d" % SHORT_GOAL and time_label.text == "0:00.0", "the HUD reads \"%s\" and \"%s\" after the restart" % [room_label.text, time_label.text])
	await _unload(main)
	return failures

## What a fresh run looks like, from any earlier state: seed, plans, rooms, counter, clock, state, player, panel.
func _fresh_run_problems(step: String, main: Node, expected_seed: int) -> Array[String]:
	var problems: Array[String] = []
	var level: Node3D = main.get_node("Level")
	var player: CharacterBody3D = level.player
	var label := "%s seed %d" % [step, expected_seed]
	_expect(problems, level.chain_seed == expected_seed, "%s: seed is %d" % [label, level.chain_seed])
	_expect(problems, _same_plans(level.chain.plans, _level_plans(step, expected_seed, 1, level.goal_room)), "%s: room 0 is not the pure-data chain's" % label)
	_expect(problems, level.rooms.size() == 1 and level.rooms.has(0) and level.current == 0, "%s: %d live rooms, current %d" % [label, level.rooms.size(), level.current])
	_expect(problems, _rooms_of(level).size() == 1, "%s: %d room nodes in the tree" % [label, _rooms_of(level).size()])
	_expect(problems, level.state == STATE_READY and level.run_time == 0.0, "%s: state %d, clock %s" % [label, level.state, level.run_time])
	_expect(problems, not level.rooms[0].door.is_open, "%s: door 0 is open" % label)
	_expect(problems, player.global_position.distance_to(Vector3(0.0, 0.0, 3.5)) < 0.05 and player.is_on_floor(), "%s: the player is at %s" % [label, player.global_position])
	_expect(problems, player.get("frozen") == false and player.velocity == Vector3.ZERO, "%s: the player is frozen or moving" % label)
	_expect(problems, (main.get_node("HUD/Stats/RoomLabel") as Label).text == "Room 0 / %d" % level.goal_room, "%s: the counter reads \"%s\"" % [label, (main.get_node("HUD/Stats/RoomLabel") as Label).text])
	_expect(problems, (main.get_node("HUD/Stats/TimeLabel") as Label).text == "0:00.0", "%s: the clock reads \"%s\"" % [label, (main.get_node("HUD/Stats/TimeLabel") as Label).text])
	_expect(problems, not (main.get_node("HUD/FinishPanel") as Control).visible, "%s: the finish panel is still up" % label)
	if level.get("new_best") != null:
		_expect(problems, level.get("new_best") == false, "%s: new_best is still set" % label)
	return problems

## A restart pressed with the player standing in the first door's trigger. Under Jolt a teleported player is
## still at the old place for the physics step right after the teleport: a trigger that is awake in that step reports the
## player, and the new room 0 opens its door at once (room 1 is built, the clock runs). The restart is delivered the way a
## key press is: buffered, and handled at the start of the next frame.
func test_restart_at_the_door(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step, true, {"goal_room": SHORT_GOAL})
	var level: Node3D = main.get_node("Level")
	var player: CharacterBody3D = level.player
	var source := FileAccess.get_file_as_string("res://steps/%s/level.gd" % step)
	for action: StringName in [&"regenerate", &"next_seed"]:
		if not source.contains("\"%s\"" % action):
			continue # N comes with step 5
		Input.action_press("move_forward")
		await _wait_physics(100)
		Input.action_release("move_forward")
		await _wait_physics(5)
		var old_trigger: Area3D = level.rooms[0].door.get_node("Trigger")
		_expect(failures, old_trigger.overlaps_body(player), "%s: the player is not in the first door's trigger (at %s)" % [action, player.global_position])
		await _press(action)
		var door: Node3D = level.rooms[0].door
		var reports: Array[int] = [0]
		(door.get_node("Trigger") as Area3D).body_entered.connect(func(_body: Node3D) -> void: reports[0] += 1)
		var woke := false
		for i in 6:
			await physics_frame
			woke = woke or reports[0] > 0 or door.is_open or level.rooms.size() > 1 or level.get("state") not in [null, STATE_READY]
		_expect(failures, not woke, "%s: the new room 0 saw the player at the old place: %d trigger reports, door open %s, %d rooms, state %s" % [action, reports[0], door.is_open, level.rooms.size(), level.get("state")])
		await _wait_physics(5)
	await _unload(main)
	return failures

## The reset has one home. Every statement that undoes a run is in start(), and only there.
func test_reset_in_one_place() -> Array[String]:
	var failures: Array[String] = []
	for step in _steps_from("step_05_restart"):
		var source := FileAccess.get_file_as_string("res://steps/%s/level.gd" % step)
		var start_at := source.find("func start() -> void:")
		var start_end := source.find("\nfunc ", start_at + 1)
		var start_body := source.substr(start_at, start_end - start_at)
		var statements: Array[String] = ["rooms.clear()", "current = 0", "run_time = 0.0", "chain = Chain.new(", "_set_state(State.READY)"]
		if step == "step_06_best_time":
			statements.append("new_best = false")
		for statement in statements:
			_expect(failures, start_body.contains(statement), "%s: start() does not contain `%s`" % [step, statement])
			_expect(failures, source.count(statement) == 1, "%s: `%s` appears %d times in level.gd, expected once (in start())" % [step, statement, source.count(statement)])
		_expect(failures, start_body.contains("room_entered.emit(current)"), "%s: start() does not announce room 0" % step)
		# The input only picks the seed and calls start().
		var input_at := source.find("func _unhandled_input(")
		var input_end := source.find("\nfunc ", input_at + 1)
		var input_body := source.substr(input_at, input_end - input_at)
		_expect(failures, input_body.count("start()") == 2 and input_body.count("chain_seed += 1") == 1, "%s: _unhandled_input does more than pick a seed and call start()" % step)
		for statement: String in ["rooms.clear()", "run_time", "player.", "current = ", "_set_state"]:
			_expect(failures, not input_body.contains(statement), "%s: _unhandled_input touches `%s`" % [step, statement])
	return failures

#endregion

#region Step 6: best times

func test_best_round_trip() -> Array[String]:
	var failures: Array[String] = []
	var path := _fresh_save_path()
	var times := BestTimes.new(path)
	_expect(failures, times.best(42) == BestTimes.NO_TIME, "a new list has a time for seed 42")
	_expect(failures, times.submit(42, 39.8167), "the first time of a seed is a best")
	_expect(failures, FileAccess.file_exists(path), "no file after the first submit")
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	_expect(failures, data is Dictionary, "the file is not a JSON object")
	if data is Dictionary:
		_expect(failures, (data as Dictionary).get("formatVersion") == 1.0, "formatVersion is %s" % (data as Dictionary).get("formatVersion"))
		var best_times: Dictionary = (data as Dictionary).get("bestTimes", {})
		_expect(failures, best_times == {"42": 39.817}, "bestTimes is %s, expected {\"42\": 39.817}" % [best_times])
	var again := BestTimes.new(path)
	_expect(failures, again.best(42) == 39.817, "reloaded: %s" % again.best(42))
	_expect(failures, again.best(43) == BestTimes.NO_TIME, "seed 43 has a time")
	_expect(failures, times.submit(-5, 12.0) and BestTimes.new(path).best(-5) == 12.0, "a negative seed does not round trip")
	_expect(failures, BestTimes.new(path).best(42) == 39.817, "seed 42 was lost when seed -5 was saved")
	return failures

func test_best_only_faster() -> Array[String]:
	var failures: Array[String] = []
	var path := _fresh_save_path()
	var times := BestTimes.new(path)
	times.submit(42, 50.0)
	_expect(failures, not times.submit(42, 60.0), "a slower time counted as a best")
	_expect(failures, not times.submit(42, 50.0), "an equal time counted as a best")
	_expect(failures, not times.submit(42, 50.0004), "a time that rounds to the same millisecond counted as a best")
	_expect(failures, times.best(42) == 50.0, "the best changed to %s" % times.best(42))
	_expect(failures, BestTimes.new(path).best(42) == 50.0, "the file changed with a slower time")
	_expect(failures, times.submit(42, 49.999), "a faster time did not count")
	_expect(failures, times.best(42) == 49.999 and BestTimes.new(path).best(42) == 49.999, "the faster time was not kept")
	_expect(failures, times.submit(43, 90.0) and times.best(43) == 90.0 and times.best(42) == 49.999, "seeds are not independent")
	_expect(failures, BestTimes.new(path).best(43) == 90.0 and BestTimes.new(path).best(42) == 49.999, "the file lost a seed")
	return failures

func test_best_missing_file() -> Array[String]:
	var failures: Array[String] = []
	var path := _fresh_save_path()
	var times := BestTimes.new(path)
	_expect(failures, times.best(1) == BestTimes.NO_TIME and times.best(42) == BestTimes.NO_TIME, "an empty list has times")
	_expect(failures, not FileAccess.file_exists(path) and not FileAccess.file_exists(path + ".bad") and not FileAccess.file_exists(path + ".tmp"), "loading a missing file wrote something")
	return failures

func test_best_damaged_file() -> Array[String]:
	var failures: Array[String] = []
	var damaged: Array[String] = [
		"{\"formatVersion\": 1, \"bestTimes\": {\"42\": 39.", # cut off in the middle of a write
		"", # empty
		"[1, 2, 3]", # valid JSON, not an object
		"\"just text\"",
		"42",
		"not json at all <<<",
		"{\"formatVersion\": 1, \"bestTimes\": [1, 2]}", # an object, but the list is not one
		"{\"formatVersion\": 1, \"bestTimes\": \"x\"}",
	]
	for text in damaged:
		var path := _fresh_save_path()
		_write_file(path, text)
		var times := BestTimes.new(path) # must not crash
		_expect(failures, times.best(42) == BestTimes.NO_TIME, "damaged %s: a time was invented" % [text])
		_expect(failures, FileAccess.file_exists(path + ".bad") and FileAccess.get_file_as_string(path + ".bad") == text, "damaged %s: not kept as .bad, unchanged" % [text])
		_expect(failures, not FileAccess.file_exists(path), "damaged %s: the damaged file is still in place" % [text])
		# The list works again, and the damaged copy stays as it was.
		_expect(failures, times.submit(42, 41.5) and BestTimes.new(path).best(42) == 41.5, "damaged %s: a new time was not saved" % [text])
		_expect(failures, FileAccess.get_file_as_string(path + ".bad") == text, "damaged %s: .bad changed when the new list was saved" % [text])
	return failures

func test_best_unknown_keys() -> Array[String]:
	var failures: Array[String] = []
	var path := _fresh_save_path()
	_write_file(path, JSON.stringify({
		"formatVersion": 3,
		"writtenBy": "9.9.9",
		"settings": {"volume": 0.5, "names": ["a", "b"]},
		"bestTimes": {"7": 12.5, "42": 50, "legacy": "n/a", "8": null, "9": "fast", "10": [1], "11": true},
	}))
	var times := BestTimes.new(path)
	_expect(failures, times.best(7) == 12.5 and times.best(42) == 50.0, "known times: %s and %s" % [times.best(7), times.best(42)])
	_expect(failures, times.best(8) == BestTimes.NO_TIME and times.best(9) == BestTimes.NO_TIME and times.best(10) == BestTimes.NO_TIME and times.best(11) == BestTimes.NO_TIME, "an odd entry counted as a time")
	_expect(failures, not times.submit(42, 51.0), "a slower time replaced an int time")
	_expect(failures, times.submit(42, 40.0), "a faster time did not replace an int time")
	_expect(failures, times.submit(9, 30.0), "a time for a seed with an odd entry was not stored")
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	_expect(failures, data.get("writtenBy") == "9.9.9", "writtenBy is gone")
	_expect(failures, data.get("settings") == {"volume": 0.5, "names": ["a", "b"]}, "settings is %s" % [data.get("settings")])
	_expect(failures, data.get("formatVersion") == 3.0, "the format version went from 3 to %s" % data.get("formatVersion"))
	var best: Dictionary = data.get("bestTimes", {})
	_expect(failures, best.get("7") == 12.5 and best.get("42") == 40.0 and best.get("9") == 30.0, "bestTimes is %s" % [best])
	_expect(failures, best.get("legacy") == "n/a" and best.has("8") and best.get("8") == null and best.get("10") == [1.0] and best.get("11") == true, "odd entries did not survive: %s" % [best])
	_expect(failures, best.size() == 7, "bestTimes has %d entries, expected 7" % best.size())
	# A file without a version gets the version of this writer.
	var plain := _fresh_save_path()
	_write_file(plain, "{\"bestTimes\": {\"1\": 5.0}}")
	var plain_times := BestTimes.new(plain)
	plain_times.submit(2, 6.0)
	var plain_data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(plain))
	_expect(failures, plain_data.get("formatVersion") == 1.0 and (plain_data.get("bestTimes") as Dictionary).size() == 2, "a file without a version: %s" % [plain_data])
	return failures

func test_best_atomic_write() -> Array[String]:
	var failures: Array[String] = []
	var path := _fresh_save_path()
	# A temp file left behind by a crash does no harm.
	_write_file(path + ".tmp", "{\"half written")
	var times := BestTimes.new(path)
	_expect(failures, times.best(42) == BestTimes.NO_TIME, "a stale temp file was read")
	_expect(failures, times.submit(42, 33.0), "the save failed with a stale temp file")
	_expect(failures, not FileAccess.file_exists(path + ".tmp"), "the temp file is still there after the save")
	_expect(failures, BestTimes.new(path).best(42) == 33.0, "the saved file does not load")
	# The old file is replaced whole: a second save still leaves a loadable file and no temp file.
	times.submit(42, 32.0)
	_expect(failures, not FileAccess.file_exists(path + ".tmp") and BestTimes.new(path).best(42) == 32.0, "the second save left a broken state")
	# The source goes temp file first, then rename (not delete then move, not a write in place).
	var source := FileAccess.get_file_as_string("res://steps/step_06_best_time/best_times.gd")
	_expect(failures, source.contains("\".tmp\"") and source.contains("rename_absolute") and source.contains("flush()"), "best_times.gd does not write a temp file, flush it and rename it")
	_expect(failures, not source.contains("remove_absolute") and not source.contains("DirAccess.remove"), "best_times.gd deletes a file")
	return failures

func test_best_write_failure() -> Array[String]:
	var failures: Array[String] = []
	var path := _save_dir.path_join("no-such-folder").path_join("best_times.json")
	var times := BestTimes.new(path)
	_expect(failures, times.submit(42, 40.0), "a failed save lost the time")
	_expect(failures, times.best(42) == 40.0, "the time is not kept in memory after a failed save")
	_expect(failures, not FileAccess.file_exists(path), "a file appeared in a folder that does not exist")
	return failures

## The label in the corner for the current seed, and how N changes it.
func test_best_label() -> Array[String]:
	var failures: Array[String] = []
	var path := _fresh_save_path()
	_write_file(path, JSON.stringify({"formatVersion": 1, "bestTimes": {"42": 39.8, "43": 70.25}}))
	var main := await _load_step("step_06_best_time", true, {"save_path": path})
	var level: Node3D = main.get_node("Level")
	var label: Label = main.get_node("HUD/Stats/BestLabel")
	_expect(failures, label.text == "Best 0:39.8", "the label reads \"%s\" for seed 42" % label.text)
	_expect(failures, label.get_theme_font_size("font_size") >= 32 and label.horizontal_alignment == HORIZONTAL_ALIGNMENT_RIGHT, "the best label is not like the other labels")
	await _action("next_seed")
	await _wait_physics(5)
	_expect(failures, level.chain_seed == 43 and label.text == "Best 1:10.2", "seed %d: the label reads \"%s\", expected \"Best 1:10.2\"" % [level.chain_seed, label.text])
	await _action("next_seed")
	await _wait_physics(5)
	_expect(failures, level.chain_seed == 44 and label.text == "Best -:--.-", "seed %d: the label reads \"%s\", expected \"Best -:--.-\"" % [level.chain_seed, label.text])
	await _action("regenerate")
	await _wait_physics(5)
	_expect(failures, level.chain_seed == 44 and label.text == "Best -:--.-", "R changed the label to \"%s\"" % label.text)
	# All three labels fit the right side of the screen without touching the map.
	for screen_size: Vector2i in [Vector2i(1920, 1080), Vector2i(1280, 720)]:
		await _set_screen(screen_size)
		var stats: Control = main.get_node("HUD/Stats")
		var screen := Rect2(Vector2.ZERO, Vector2(screen_size))
		_expect(failures, screen.encloses(stats.get_global_rect()) and not stats.get_global_rect().intersects((main.get_node("HUD/DebugMap") as Control).get_global_rect()), "%dx%d: the stats box %s does not fit" % [screen_size.x, screen_size.y, stats.get_global_rect()])
	await _unload(main)
	return failures

func test_best_in_level() -> Array[String]:
	var failures: Array[String] = []

	# 1. Slower than the saved time: no "New best!", the file is untouched.
	var path := _fresh_save_path()
	var before := JSON.stringify({"formatVersion": 1, "settings": {"x": 1}, "bestTimes": {"42": 0.5}}, "\t")
	_write_file(path, before)
	var main := await _load_step("step_06_best_time", true, {"save_path": path, "goal_room": SHORT_GOAL})
	var level: Node3D = main.get_node("Level")
	var new_best: Label = main.get_node("HUD/FinishPanel/Rows/NewBest")
	_expect(failures, not new_best.visible, "\"New best!\" is visible before the finish")
	_fast_forward(true)
	var finished := await _walk_to_finish(level, Autopilot.new(level))
	_fast_forward(false)
	_expect(failures, finished, "run 1 did not finish")
	_expect(failures, level.new_best == false and not new_best.visible, "a slower run says \"New best!\"")
	_expect(failures, FileAccess.get_file_as_string(path) == before, "a slower run changed the file")
	_expect(failures, (main.get_node("HUD/Stats/BestLabel") as Label).text == "Best 0:00.5", "the label reads \"%s\"" % (main.get_node("HUD/Stats/BestLabel") as Label).text)
	await _unload(main)

	# 2. Faster than the saved time: "New best!", saved, unknown keys kept.
	path = _fresh_save_path()
	_write_file(path, JSON.stringify({"formatVersion": 1, "settings": {"x": 1}, "bestTimes": {"42": 999.0, "7": 5.5}}))
	main = await _load_step("step_06_best_time", true, {"save_path": path, "goal_room": SHORT_GOAL})
	level = main.get_node("Level")
	new_best = main.get_node("HUD/FinishPanel/Rows/NewBest")
	_fast_forward(true)
	finished = await _walk_to_finish(level, Autopilot.new(level))
	_fast_forward(false)
	_expect(failures, finished, "run 2 did not finish")
	var run_time: float = level.run_time
	_expect(failures, level.new_best == true and new_best.visible and new_best.text == "New best!", "a faster run does not say \"New best!\"")
	var saved: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	_expect(failures, absf((saved.bestTimes as Dictionary).get("42", 0.0) - run_time) < 0.0006, "saved %s, the run took %.4f s" % [(saved.bestTimes as Dictionary).get("42"), run_time])
	_expect(failures, (saved.bestTimes as Dictionary).get("7") == 5.5 and saved.get("settings") == {"x": 1.0}, "other entries did not survive: %s" % [saved])
	var best_text := "Best " + str(load("res://steps/step_06_best_time/hud.gd").call("format_time", BestTimes.new(path).best(42)))
	_expect(failures, (main.get_node("HUD/Stats/BestLabel") as Label).text == best_text, "the label reads \"%s\", expected \"%s\"" % [(main.get_node("HUD/Stats/BestLabel") as Label).text, best_text])
	var first_best := BestTimes.new(path).best(42)

	# 3. Restart, the same seed again but slower (the player waits at every door): not a best, the file stays.
	await _action("regenerate")
	await _wait_physics(10)
	_expect(failures, not new_best.visible and level.new_best == false, "\"New best!\" is still up after R")
	_fast_forward(true)
	finished = await _walk_to_finish(level, Autopilot.new(level), 90)
	_fast_forward(false)
	_expect(failures, finished, "run 3 did not finish")
	_expect(failures, level.run_time > run_time + 2.0, "the slow run took %.1f s, the first %.1f s" % [level.run_time, run_time])
	_expect(failures, level.new_best == false and not new_best.visible, "a slower second run says \"New best!\"")
	_expect(failures, BestTimes.new(path).best(42) == first_best, "the slower run replaced the best")

	# 4. Another seed has its own list: its first run is a best, and seed 42 is not touched.
	await _action("next_seed")
	await _wait_physics(10)
	_expect(failures, level.chain_seed == 43 and (main.get_node("HUD/Stats/BestLabel") as Label).text == "Best -:--.-", "seed 43 starts with a best time")
	_fast_forward(true)
	finished = await _walk_to_finish(level, Autopilot.new(level))
	_fast_forward(false)
	_expect(failures, finished and level.new_best == true and new_best.visible, "the first run of seed 43 is not a new best")
	_expect(failures, BestTimes.new(path).best(43) > 0.0 and BestTimes.new(path).best(42) == first_best, "seed 43 or seed 42 is wrong in the file")
	await _unload(main)
	return failures

#endregion

#region Full run

func test_full_run() -> Array[String]:
	var failures: Array[String] = []
	var path := _fresh_save_path()
	var main := await _load_step("step_06_best_time", true, {"save_path": path})
	var level: Node3D = main.get_node("Level")
	var pilot := Autopilot.new(level)
	var changes: Array[int] = []
	level.connect("state_changed", func(new_state: int) -> void: changes.append(new_state))
	_expect(failures, level.chain_seed == 42 and level.goal_room == 20, "seed %d, goal room %d, expected 42 and 20" % [level.chain_seed, level.goal_room])
	_fast_forward(true)
	var started := Time.get_ticks_msec()
	var finished := await _walk_to_finish(level, pilot, 0, 60 * 60 * 5)
	_fast_forward(false)
	var wall := (Time.get_ticks_msec() - started) / 1000.0
	_expect(failures, finished, "the run did not finish (state %d, room %d, %.1f s)" % [level.state, level.current, level.run_time])
	_expect(failures, changes == [STATE_RUNNING, STATE_FINISHED], "state changes %s" % [changes])
	_expect(failures, level.current == 20 and level.chain.goal_index == 20 and level.chain.plans.size() == 21, "finished in room %d with %d plans (goal_index %d)" % [level.current, level.chain.plans.size(), level.chain.goal_index])
	var run_time: float = level.run_time
	# 20 rooms of 10 to 18 m at 5 m/s: well under two minutes for the autopilot, a person takes longer.
	_expect(failures, run_time > 30.0 and run_time < 120.0, "the run took %.1f s" % run_time)
	print("        full run, seed 42: %.2f s of game time (%d physics ticks), %.1f s of wall time at %dx" % [run_time, roundi(run_time * 60.0), wall, SPEED_UP])

	var panel: Control = main.get_node("HUD/FinishPanel")
	var format_time: GDScript = load("res://steps/step_06_best_time/hud.gd")
	_expect(failures, panel.visible and (main.get_node("HUD/FinishPanel/Rows/FinishTitle") as Label).text == "Finished!", "the finish panel is not up")
	_expect(failures, (main.get_node("HUD/FinishPanel/Rows/FinishTime") as Label).text == str(format_time.call("format_time", run_time)), "the panel time is \"%s\"" % (main.get_node("HUD/FinishPanel/Rows/FinishTime") as Label).text)
	_expect(failures, (main.get_node("HUD/FinishPanel/Rows/NewBest") as Label).visible and level.new_best == true, "no \"New best!\" for the first run")
	_expect(failures, (main.get_node("HUD/Stats/RoomLabel") as Label).text == "Room 20 / 20", "the counter reads \"%s\"" % (main.get_node("HUD/Stats/RoomLabel") as Label).text)
	_expect(failures, (main.get_node("HUD/Stats/BestLabel") as Label).text == "Best " + str(format_time.call("format_time", run_time)), "the best label reads \"%s\"" % (main.get_node("HUD/Stats/BestLabel") as Label).text)
	_expect(failures, level.player.get("frozen") == true and level.player.velocity == Vector3.ZERO, "the player is not stopped")
	var saved: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	_expect(failures, saved is Dictionary and ((saved as Dictionary).get("bestTimes", {}) as Dictionary).has("42"), "no time saved for seed 42: %s" % [saved])
	if saved is Dictionary:
		_expect(failures, absf(((saved as Dictionary).bestTimes as Dictionary).get("42", 0.0) - run_time) < 0.0006, "saved %s, the run took %.4f s" % [((saved as Dictionary).bestTimes as Dictionary).get("42"), run_time])
	_expect(failures, not level.rooms.is_empty() and level.rooms.size() <= 2, "%d rooms live at the finish" % level.rooms.size())

	# R: the same seed, same rooms again; the saved time is still there.
	await _action("regenerate")
	await _wait_physics(10)
	_expect(failures, level.chain_seed == 42 and level.state == STATE_READY and level.run_time == 0.0 and not panel.visible, "R after the finish did not start a clean run")
	_expect(failures, (main.get_node("HUD/Stats/BestLabel") as Label).text == "Best " + str(format_time.call("format_time", run_time)), "the best time is gone after R: \"%s\"" % (main.get_node("HUD/Stats/BestLabel") as Label).text)
	await _unload(main)
	return failures

#endregion

#region Graybox standard: closed rooms, materials, lighting

func test_materials() -> Array[String]:
	var failures: Array[String] = []
	var grid := load(MATERIAL_DIR + "grid_1m.png") as Texture2D
	_expect(failures, grid != null and grid.get_size() == Vector2(256.0, 256.0), "grid_1m.png is not a 256x256 texture")
	if grid == null:
		return failures

	# One tile is 1 m: a dark line on the tile border, a fainter one at 0.5 m, the same on both axes.
	var image := grid.get_image()
	var fill := image.get_pixel(100, 100)
	var half_line := image.get_pixel(127, 100)
	var tile_line := image.get_pixel(0, 100)
	_expect(failures, tile_line.r < half_line.r and half_line.r < fill.r, "grid lines: tile %.2f, half %.2f, fill %.2f" % [tile_line.r, half_line.r, fill.r])
	_expect(failures, image.get_pixel(255, 100) == tile_line and image.get_pixel(100, 0) == tile_line and image.get_pixel(100, 255) == tile_line, "the tile border line is not centred on the border")
	_expect(failures, image.get_pixel(100, 127) == half_line and image.get_pixel(100, 128) == half_line and image.get_pixel(128, 100) == half_line, "the 0.5 m line is not the same on both axes")
	_expect(failures, image.has_mipmaps(), "the grid is imported without mipmaps: it would shimmer at a distance")

	# Neutral gray floor, walls and ceiling in the midtone range (50-100 percent), floor lighter than walls.
	var targets: Dictionary[String, float] = {"floor": 0.70, "wall": 0.55, "ceiling": 0.60}
	var fills: Dictionary[String, Color] = {}
	for material_name: String in targets:
		var material := load(MATERIAL_DIR + material_name + ".tres") as StandardMaterial3D
		_expect(failures, material != null, "%s.tres is not a StandardMaterial3D" % material_name)
		if material == null:
			continue
		var shown := (material.albedo_color.srgb_to_linear() * fill.srgb_to_linear()).linear_to_srgb()
		fills[material_name] = shown
		_expect(failures, material.albedo_texture != null and material.albedo_texture.resource_path == grid.resource_path, "%s.tres does not use the shared grid" % material_name)
		_expect(failures, material.uv1_triplanar and material.uv1_world_triplanar, "%s.tres is not world triplanar" % material_name)
		_expect(failures, material.uv1_scale.is_equal_approx(Vector3.ONE), "%s.tres: uv1_scale %s, one tile must be 1 m (scale 1)" % [material_name, material.uv1_scale])
		_expect(failures, material.shading_mode == BaseMaterial3D.SHADING_MODE_PER_PIXEL, "%s.tres is unlit" % material_name)
		_expect(failures, material.texture_filter == BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC, "%s.tres: texture_filter %d" % [material_name, material.texture_filter])
		_expect(failures, shown.r >= 0.5 and shown.r <= 1.0, "%s.tres: albedo %.2f is outside 50-100 percent" % [material_name, shown.r])
		_expect(failures, absf(shown.r - targets[material_name]) < 0.02, "%s.tres: albedo %.3f, expected about %.2f" % [material_name, shown.r, targets[material_name]])
		_expect(failures, absf(shown.r - shown.g) < 0.01 and absf(shown.r - shown.b) < 0.01, "%s.tres is not neutral gray" % material_name)
	if fills.size() == 3:
		_expect(failures, fills["floor"].r > fills["wall"].r + 0.1, "the floor must be clearly lighter than the walls (%.2f vs %.2f)" % [fills["floor"].r, fills["wall"].r])

	# The door and the goal are the warm accents, and brighter than the gray room around them (squint test).
	var wall_light := 0.0
	if fills.has("wall"):
		wall_light = (load(MATERIAL_DIR + "wall.tres") as StandardMaterial3D).albedo_color.srgb_to_linear().get_luminance() * fill.srgb_to_linear().r
	for accent: String in ["door", "goal"]:
		var material := load(MATERIAL_DIR + accent + ".tres") as StandardMaterial3D
		_expect(failures, material != null, "%s.tres is not a StandardMaterial3D" % accent)
		if material == null:
			continue
		_expect(failures, material.shading_mode == BaseMaterial3D.SHADING_MODE_PER_PIXEL, "%s.tres is unlit" % accent)
		_expect(failures, material.albedo_texture == null, "%s.tres has a texture: the accent is a flat colour" % accent)
		_expect(failures, material.albedo_color.h > 0.04 and material.albedo_color.h < 0.16 and material.albedo_color.s > 0.7 and material.albedo_color.v > 0.9, "%s.tres %s is not a saturated warm colour" % [accent, material.albedo_color])
		var light := material.albedo_color.srgb_to_linear().get_luminance()
		_expect(failures, light > 1.5 * wall_light, "%s luminance %.3f is only %.2fx the wall's %.3f" % [accent, light, light / wall_light, wall_light])
	var door := load(MATERIAL_DIR + "door.tres") as StandardMaterial3D
	var goal := load(MATERIAL_DIR + "goal.tres") as StandardMaterial3D
	if door != null and goal != null:
		_expect(failures, goal.albedo_color.h > door.albedo_color.h and goal.albedo_color.srgb_to_linear().get_luminance() > door.albedo_color.srgb_to_linear().get_luminance(), "the goal gold is not the brighter, yellower step from the door's orange")
		_expect(failures, goal.emission_enabled and goal.emission_energy_multiplier <= 1.0, "the goal does not glow softly")

	# The lamp block glows but is still a lit material.
	var fixture := load(MATERIAL_DIR + "fixture.tres") as StandardMaterial3D
	_expect(failures, fixture != null and fixture.emission_enabled and fixture.emission_energy_multiplier >= 1.0, "fixture.tres is not emissive")
	_expect(failures, fixture != null and fixture.shading_mode == BaseMaterial3D.SHADING_MODE_PER_PIXEL, "fixture.tres is unlit")

	# No scene brings its own material: floors, walls, ceilings, lamps, doors and the pad all come from res://materials.
	var scenes := 0
	for step in STEPS:
		for file in DirAccess.get_files_at("res://steps/" + step):
			if file.ends_with(".tscn"):
				scenes += 1
				var text := FileAccess.get_file_as_string("res://steps/%s/%s" % [step, file])
				_expect(failures, not text.contains('[sub_resource type="StandardMaterial3D"') and not text.contains("albedo_color"), "%s/%s defines a material of its own" % [step, file])
	_expect(failures, scenes >= 60, "found only %d scenes" % scenes)
	return failures

func test_graybox_rooms(step: String) -> Array[String]:
	var failures: Array[String] = []
	var files: Array[String] = []
	for file in DirAccess.get_files_at("res://steps/" + step):
		if file.begins_with("room_") and file.ends_with(".tscn"):
			files.append(file)
	files.sort()
	var expected := ROOM_TYPES.size() + (0 if step in ["step_00_start", "step_01_room_counter"] else 1)
	_expect(failures, files.size() == expected, "%d room scenes, expected %d" % [files.size(), expected])

	# Far apart, so that a ray only ever sees the room it starts in.
	var holder := Node3D.new()
	root.add_child(holder)
	for i in files.size():
		var room := (load("res://steps/%s/%s" % [step, files[i]]) as PackedScene).instantiate() as Node3D
		room.position = Vector3(i * 40.0, 0.0, 0.0)
		holder.add_child(room)
	await _wait_physics(5) # the CSG shapes build their collision
	for room in holder.get_children():
		failures.append_array(_graybox_problems(room as Node3D, step))
	root.remove_child(holder)
	holder.free()
	return failures

## Everything the graybox standard asks of one room module, as problems (empty = fine).
func _graybox_problems(room: Node3D, step: String) -> Array[String]:
	var problems: Array[String] = []
	var label := room.scene_file_path.trim_prefix("res://steps/")
	var player := (load("res://steps/%s/player.tscn" % step) as PackedScene).instantiate()
	var capsule := (player.get_node("CollisionShape3D") as CollisionShape3D).shape as CapsuleShape3D
	player.free()

	# Floor: 0.2 m thick, its top at y = 0.
	var floor_box := room.get_node("Shell/Floor") as CSGBox3D
	var footprint := Vector2(floor_box.size.x, floor_box.size.z)
	_expect(problems, is_equal_approx(floor_box.size.y, SLAB_THICKNESS) and is_zero_approx(floor_box.position.y + floor_box.size.y / 2.0), "%s: the floor is %.2f m thick with its top at y = %.2f" % [label, floor_box.size.y, floor_box.position.y + floor_box.size.y / 2.0])
	_expect(problems, floor_box.material != null and floor_box.material.resource_path == MATERIAL_DIR + "floor.tres", "%s: the floor does not use floor.tres" % label)

	# Walls: 0.2 x 3.0 m, standing on the floor, flush with the footprint edge; cutters 1.6 x 2.4 m and deeper than the wall.
	for wall_name: String in ["WallEntrance", "WallFar", "WallLeft", "WallRight"]:
		var wall := room.get_node("Shell/" + wall_name) as CSGBox3D
		var along_z := wall_name.begins_with("WallE") or wall_name == "WallFar"
		var thickness := wall.size.z if along_z else wall.size.x
		var centre := absf(wall.position.z) if along_z else absf(wall.position.x)
		var half := footprint.y / 2.0 if along_z else footprint.x / 2.0
		_expect(problems, is_equal_approx(thickness, WALL_THICKNESS) and is_equal_approx(wall.size.y, WALL_HEIGHT), "%s: %s is %.2f m thick and %.2f m high" % [label, wall_name, thickness, wall.size.y])
		_expect(problems, is_zero_approx(wall.position.y - wall.size.y / 2.0), "%s: %s does not stand on the floor" % [label, wall_name])
		_expect(problems, is_equal_approx(centre + thickness / 2.0, half), "%s: %s is not flush with the footprint edge" % [label, wall_name])
		_expect(problems, wall.material != null and wall.material.resource_path == MATERIAL_DIR + "wall.tres", "%s: %s does not use wall.tres" % [label, wall_name])
		for cutter in wall.get_children():
			var hole := cutter as CSGBox3D
			var width := maxf(hole.size.x, hole.size.z)
			var depth := minf(hole.size.x, hole.size.z)
			_expect(problems, hole.operation == CSGShape3D.OPERATION_SUBTRACTION, "%s: %s/%s does not subtract" % [label, wall_name, hole.name])
			_expect(problems, is_equal_approx(width, DOORWAY_WIDTH) and is_equal_approx(hole.size.y, DOORWAY_HEIGHT), "%s: %s is %.2f x %.2f m, expected 1.6 x 2.4" % [label, hole.name, width, hole.size.y])
			_expect(problems, depth >= thickness + 0.1, "%s: %s is only %.2f m deep for a %.2f m wall" % [label, hole.name, depth, thickness])
			_expect(problems, is_zero_approx(wall.position.y + hole.position.y - hole.size.y / 2.0), "%s: %s does not start at the floor" % [label, hole.name])
			_expect(problems, hole.material != null and hole.material.resource_path == MATERIAL_DIR + "wall.tres", "%s: %s does not use wall.tres" % [label, hole.name])
			_expect(problems, width >= 2.0 * capsule.radius * 2.0 and hole.size.y >= capsule.height + 0.6, "%s: %s is too small for the player (2x width, 0.6 m head room)" % [label, hole.name])

	# Ceiling: its own CSG shape beside the Shell, 0.2 m thick on top of the walls, collision, layer 2 only.
	var ceiling := room.get_node("Ceiling") as CSGBox3D
	_expect(problems, ceiling.get_parent() == room and not ceiling.is_class("CSGCombiner3D"), "%s: the Ceiling is not a direct child of the room" % label)
	_expect(problems, ceiling.use_collision, "%s: the Ceiling has no collision" % label)
	_expect(problems, ceiling.layers == CEILING_LAYER, "%s: the Ceiling is on layers %d, expected only layer 2" % [label, ceiling.layers])
	_expect(problems, is_equal_approx(ceiling.size.y, SLAB_THICKNESS) and is_equal_approx(ceiling.position.y - ceiling.size.y / 2.0, WALL_HEIGHT), "%s: the Ceiling is %.2f m thick with its bottom at y = %.2f, expected 0.2 m at 3.0" % [label, ceiling.size.y, ceiling.position.y - ceiling.size.y / 2.0])
	_expect(problems, is_equal_approx(ceiling.size.x, footprint.x) and is_equal_approx(ceiling.size.z, footprint.y), "%s: the Ceiling does not cover the footprint" % label)
	_expect(problems, ceiling.material != null and ceiling.material.resource_path == MATERIAL_DIR + "ceiling.tres", "%s: the Ceiling does not use ceiling.tres" % label)

	# The lamp: one warm omni light near the ceiling centre without shadows, range over the whole room, paired with a visible block on layer 2.
	var light := room.get_node("RoomLight") as OmniLight3D
	var farthest := Vector3(footprint.x / 2.0, light.position.y, footprint.y / 2.0).length()
	_expect(problems, not light.shadow_enabled, "%s: RoomLight casts shadows" % label)
	_expect(problems, light.light_color.r >= light.light_color.g and light.light_color.g >= light.light_color.b and light.light_color.b < 0.95, "%s: RoomLight is not warm white" % label)
	_expect(problems, light.omni_range >= farthest, "%s: RoomLight range %.1f does not reach the far corner (%.1f m)" % [label, light.omni_range, farthest])
	_expect(problems, light.position.y > 2.2 and light.position.y < WALL_HEIGHT and absf(light.position.x) < 0.01 and absf(light.position.z) < 0.01, "%s: RoomLight is not near the ceiling centre (%s)" % [label, light.position])
	var fixture := room.get_node("Fixture") as MeshInstance3D
	var block := (fixture.mesh as BoxMesh)
	_expect(problems, fixture.layers == CEILING_LAYER, "%s: the Fixture is on layers %d, expected only layer 2" % [label, fixture.layers])
	_expect(problems, block.material != null and block.material.resource_path == MATERIAL_DIR + "fixture.tres", "%s: the Fixture does not use fixture.tres" % label)
	_expect(problems, is_equal_approx(fixture.position.y + block.size.y / 2.0, WALL_HEIGHT) and Vector2(fixture.position.x - light.position.x, fixture.position.z - light.position.z).length() < 0.01, "%s: the Fixture does not hang under the ceiling above the light" % label)

	# Closed: straight up from anywhere in the room hits the ceiling at 3.0 m, straight down the floor.
	var space := room.get_world_3d().direct_space_state
	var spots: Array[Vector2] = [Vector2.ZERO, footprint / 4.0, footprint * Vector2(-0.25, 0.25), footprint * Vector2(0.25, -0.25), -footprint / 4.0]
	for spot in spots:
		var from := room.global_position + Vector3(spot.x, 1.0, spot.y)
		var up := space.intersect_ray(PhysicsRayQueryParameters3D.create(from, from + Vector3(0.0, 2.5, 0.0)))
		if up.is_empty():
			problems.append("%s: a ray straight up from (%.1f, 1, %.1f) does not hit the ceiling" % [label, spot.x, spot.y])
		else:
			var hit_y: float = up["position"].y
			_expect(problems, absf(hit_y - WALL_HEIGHT) < 0.01, "%s: the ray up from (%.1f, 1, %.1f) hits at y = %.2f, expected 3.0" % [label, spot.x, spot.y, hit_y])
			_expect(problems, up["collider"] == ceiling, "%s: the ray up hit %s, not the Ceiling" % [label, up["collider"]])
		var down := space.intersect_ray(PhysicsRayQueryParameters3D.create(from, from + Vector3(0.0, -2.0, 0.0)))
		_expect(problems, not down.is_empty() and absf((down["position"] as Vector3).y) < 0.01, "%s: a ray straight down from (%.1f, 1, %.1f) misses the floor" % [label, spot.x, spot.y])
	return problems

func test_lighting(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step, false)
	var environment := (main.get_node("WorldEnvironment") as WorldEnvironment).environment
	_expect(failures, environment.background_mode == Environment.BG_SKY and environment.sky != null and environment.sky.sky_material is ProceduralSkyMaterial, "the ProceduralSky is gone")
	_expect(failures, environment.ambient_light_source == Environment.AMBIENT_SOURCE_COLOR or environment.ambient_light_source == Environment.AMBIENT_SOURCE_SKY, "ambient light source %d: the closed rooms get no fill" % environment.ambient_light_source)
	# Ambient light alone must not leave the darkest surface (the walls) black: at least 0.35 displayed.
	var fill := environment.ambient_light_energy * environment.ambient_light_color.srgb_to_linear().get_luminance()
	if environment.ambient_light_source == Environment.AMBIENT_SOURCE_SKY:
		fill = environment.ambient_light_energy * 0.3 ## The darkest part of the procedural sky.
	var wall := load(MATERIAL_DIR + "wall.tres") as StandardMaterial3D
	var wall_albedo := wall.albedo_color.srgb_to_linear().r * (load(MATERIAL_DIR + "grid_1m.png") as Texture2D).get_image().get_pixel(100, 100).srgb_to_linear().r
	var shown := (wall_albedo * fill)
	var shown_srgb := Color(shown, shown, shown).linear_to_srgb().r
	_expect(failures, shown_srgb >= 0.35, "ambient fill %.2f lights the walls to only %.2f (displayed); unlit corners must not be black" % [fill, shown_srgb])
	var sun := main.get_node("DirectionalLight3D") as DirectionalLight3D
	_expect(failures, sun.shadow_enabled, "the sun has no shadows: it would light the rooms through the ceilings")
	await _unload(main)
	return failures

func test_player_camera(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step, false)
	var player: CharacterBody3D = main.get_node("Level").player
	var camera: Camera3D = player.get_node("Head/Camera3D")
	_expect(failures, camera.cull_mask == ALL_LAYERS, "the player's cull_mask is %d, expected all %d layers" % [camera.cull_mask, ALL_LAYERS])
	_expect(failures, (camera.cull_mask & CEILING_LAYER) != 0, "the player's camera does not draw layer 2: no ceiling, no lamp")
	_expect(failures, main.find_child("OverviewCamera", true, false) == null, "a cutaway camera is left in a player step")
	await _unload(main)
	return failures

## The underside of a room's ceiling, in world space.
func _ceiling_bottom(room: Node3D) -> float:
	var ceiling := room.get_node("Ceiling") as CSGBox3D
	return ceiling.global_position.y - ceiling.size.y / 2.0

#endregion

func test_scene_runs(step: String) -> Array[String]:
	var failures: Array[String] = []
	var main := await _load_step(step, false)
	for i in 30:
		await process_frame
	_expect(failures, is_instance_valid(main) and main.is_inside_tree(), "scene left the tree")
	await _unload(main)
	return failures

#region Helpers

func _report(test_name: String, failures: Array[String]) -> void:
	var script_errors := _script_errors.count - _script_errors_reported
	_script_errors_reported = _script_errors.count
	if script_errors > 0: # the test stopped at the failing line and the engine returned an empty array, which would read as a pass
		failures.insert(0, "the test stopped with a script error: see the log")
	if failures.is_empty():
		_passed += 1
		print("PASS  ", test_name)
		return
	_failed += 1
	print("FAIL  ", test_name)
	for message: String in failures.slice(0, 8):
		print("        ", message)
	if failures.size() > 8:
		print("        ... and %d more" % (failures.size() - 8))

func _skip(test_name: String, reason: String) -> void:
	_skipped += 1
	print("SKIP  ", test_name)
	print("        ", reason)

func _expect(failures: Array[String], condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)

## Instances a step's main scene. By default it waits until the CSG shapes have built their collision.
## props are set on the Level before it enters the tree (goal_room, chain_seed, save_path ...).
## A level that saves gets a fresh temporary save file unless props bring one.
func _load_step(step: String, settle := true, props := {}) -> Node:
	var scene: PackedScene = load("res://steps/%s/main.tscn" % step)
	var main := scene.instantiate()
	var level := main.get_node_or_null("Level")
	if level != null:
		if level.get("save_path") != null and not props.has("save_path"):
			level.set("save_path", _fresh_save_path())
		for key: String in props:
			level.set(key, props[key])
	root.add_child(main)
	if settle:
		await _wait_physics(10)
	return main

func _unload(main: Node) -> void:
	for action: String in ["move_forward", "move_back", "move_left", "move_right", "look_left", "look_right", "look_up", "look_down", "jump"]:
		Input.action_release(action)
	root.remove_child(main)
	main.free()
	await process_frame

## A path in the temporary test folder that no file exists at.
func _fresh_save_path() -> String:
	_save_counter += 1
	DirAccess.make_dir_recursive_absolute(_save_dir)
	return _save_dir.path_join("best_times_%d.json" % _save_counter)

func _write_file(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()

func _wipe_save_dir() -> void:
	if not DirAccess.dir_exists_absolute(_save_dir):
		return
	for file in DirAccess.get_files_at(_save_dir):
		DirAccess.remove_absolute(_save_dir.path_join(file))
	DirAccess.remove_absolute(_save_dir)

## Runs the simulation faster than real time with the same 1/60 s steps: the engine ticks
## SPEED_UP times as often and hands out SPEED_UP times the delta of each (smaller) tick.
func _fast_forward(on: bool) -> void:
	Engine.physics_ticks_per_second = 60 * (SPEED_UP if on else 1)
	Engine.time_scale = float(SPEED_UP) if on else 1.0

## Sets the size of the game window (headless: the root viewport) and waits for the layout.
## The engine ignores the first size it is given after start-up, so it asks again.
func _set_screen(size: Vector2i) -> void:
	for attempt in 3:
		root.size = size
		for i in 3:
			await process_frame
		if root.size == size:
			return

func _wait_physics(frames: int) -> void:
	for i in frames:
		await physics_frame

func _action(action: StringName) -> void:
	var press := InputEventAction.new()
	press.action = action
	press.pressed = true
	Input.parse_input_event(press)
	Input.flush_buffered_events()
	await process_frame

## Presses an action the way a key does: the event is buffered and handled at the start of the next frame, before that
## frame's physics steps. (_action() hands it over at once, in the middle of a physics frame.)
func _press(action: StringName) -> void:
	var press := InputEventAction.new()
	press.action = action
	press.pressed = true
	Input.parse_input_event(press)
	await physics_frame

#endregion
