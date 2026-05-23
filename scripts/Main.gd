## ═══════════════════════════════════════════════════════════════
##  V O I D   W A L K E R  —  Main.gd  (v3)
##
##  New in v3:
##    ∙ Camera2D screen shake  (death, trail-eaten, milestones)
##    ∙ 3 star types:  Regular ★  /  Freeze ❄  /  Nova ✦
##    ∙ Freeze star  — slows all voids to 15% for 4 s
##    ∙ Nova star    — shockwave pushes voids, clears trail radius
##    ∙ Nova explosion rings visual
##    ∙ Death debris particles  (trail explodes outward)
##    ∙ Survival score  (+1 every 5 s, +5 every 30 s)
##    ∙ Vignette overlay
##    ∙ Void "hunger flash" colour pulse when eating trail
##    ∙ Better combo pop styling
## ═══════════════════════════════════════════════════════════════
extends Node2D

# ── Constants ─────────────────────────────────────────────────────────────────
const CELL          := 20
const COLS          := 40
const ROWS          := 30
const W             := COLS * CELL     # 800
const H             := ROWS * CELL     # 600
const MOVE_SEC      := 0.13
const COMBO_WINDOW  := 2.5
const COMBO_MAX     := 8
const WARN_DURATION := 1.8
const GRACE_SEC     := 3.0
const NOVA_RADIUS   := 110.0           # pixel radius of nova shockwave
const FREEZE_DUR    := 4.0             # seconds voids stay frozen

# ── Enums ─────────────────────────────────────────────────────────────────────
enum State    { MENU, PLAYING, DEAD }
enum VoidType { SEEKER, DRIFTER, AMBUSHER }
enum StarType { REGULAR, FREEZE, NOVA }

# ── Game state ────────────────────────────────────────────────────────────────
var game_state  : State  = State.MENU
var score       : int    = 0
var best_score  : int    = 0

# ── Player ────────────────────────────────────────────────────────────────────
var p_pos         : Vector2i = Vector2i(COLS / 2, ROWS / 2)
var p_dir         : Vector2i = Vector2i(1, 0)
var p_next_dir    : Vector2i = Vector2i(1, 0)
var p_trail       : Array    = []
var p_max_trail   : int      = 12
var p_alive       : bool     = true
var p_eat_flash   : float    = 0.0
var p_grace       : float    = 0.0

# ── Combo ─────────────────────────────────────────────────────────────────────
var combo         : int   = 1
var combo_timer   : float = 0.0

# ── Global freeze ─────────────────────────────────────────────────────────────
var freeze_timer  : float = 0.0    # > 0 → all voids slowed

# ── Voids ─────────────────────────────────────────────────────────────────────
var void_list     : Array = []

# ── Stars  {pos, age, type} ───────────────────────────────────────────────────
var star_data     : Array = []

# ── Explosions  {pos, radius, life, max_life} ─────────────────────────────────
var explosions    : Array = []

# ── Debris particles  {pos, vel, life, max_life, col} ────────────────────────
var debris        : Array = []

# ── Popups / banners ──────────────────────────────────────────────────────────
var popups        : Array = []
var announcements : Array = []

# ── Timers / animation ────────────────────────────────────────────────────────
var move_accum    : float = 0.0
var game_time     : float = 0.0
var glow_pulse    : float = 0.0
var death_timer   : float = 0.0
var danger_glow   : float = 0.0
var survival_tick : float = 0.0    # every 5 s → +1 pt
var survival_milestone : float = 0.0  # every 30 s → +5 pt

# ── Milestones ────────────────────────────────────────────────────────────────
var milestones_hit : Array = []

# ── Camera / screen shake ─────────────────────────────────────────────────────
var camera        : Camera2D
var shake_power   : float = 0.0
var shake_decay   : float = 8.0    # how fast shake dies per second

# ── Font + bg particles ───────────────────────────────────────────────────────
var font          : Font
var bg_particles  : Array = []

# ─────────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	font = ThemeDB.fallback_font

	# Camera for screen shake
	camera = Camera2D.new()
	camera.enabled = true
	add_child(camera)

	_load_best()

	for _i in 180:
		bg_particles.append({
			"x":     randf() * W,
			"y":     randf() * H,
			"r":     randf() * 1.2 + 0.3,
			"b":     randf(),
			"drift": (randf() - 0.5) * 0.12
		})

# ── Persistence ───────────────────────────────────────────────────────────────
func _load_best() -> void:
	var f := FileAccess.open("user://best.txt", FileAccess.READ)
	if f: best_score = int(f.get_as_text().strip_edges()); f.close()

func _save_best() -> void:
	var f := FileAccess.open("user://best.txt", FileAccess.WRITE)
	if f: f.store_string(str(best_score)); f.close()

# ── Shake helper ──────────────────────────────────────────────────────────────
func _shake(power: float) -> void:
	shake_power = maxf(shake_power, power)

# ── Main loop ─────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	game_time  += delta
	glow_pulse  = sin(game_time * 6.0) * 0.5 + 0.5

	# Screen shake
	if shake_power > 0.01:
		camera.offset = Vector2(
			randf_range(-shake_power, shake_power),
			randf_range(-shake_power, shake_power))
		shake_power = maxf(0.0, shake_power - shake_decay * delta)
	else:
		camera.offset = Vector2.ZERO
		shake_power   = 0.0

	# Bg particles drift
	for p in bg_particles:
		p["x"] = fmod(p["x"] + p["drift"] + W, W)

	match game_state:
		State.PLAYING:
			p_grace       = maxf(0.0, p_grace - delta)
			freeze_timer  = maxf(0.0, freeze_timer - delta)

			# Combo decay
			if combo_timer > 0.0:
				combo_timer -= delta
				if combo_timer <= 0.0: combo = 1

			# Grid tick
			move_accum += delta
			if move_accum >= MOVE_SEC:
				move_accum -= MOVE_SEC
				_step()

			_update_voids(delta)
			_check_milestones()

			# Survival score
			survival_tick      += delta
			survival_milestone += delta
			if survival_tick >= 5.0:
				survival_tick -= 5.0
				score += 1
			if survival_milestone >= 30.0:
				survival_milestone -= 30.0
				score += 5
				popups.append({
					"pos": Vector2(W * 0.5 - 30, H * 0.5 + 145),
					"text": "+5 SURVIVAL",
					"life": 1.1, "color": Color(0.4, 1.0, 0.6), "size": 13
				})

			p_eat_flash = maxf(0.0, p_eat_flash - delta * 5.0)

			# Nearest void for danger glow
			var pp := _g2p(p_pos)
			var nearest := INF
			for v in void_list:
				if v["active"]:
					nearest = minf(nearest, (v["pos"] as Vector2).distance_to(pp))
			danger_glow = clampf(1.0 - nearest / 120.0, 0.0, 1.0) if nearest < INF else 0.0

		State.DEAD:
			death_timer += delta
			_update_voids(delta)
			danger_glow = maxf(0.0, danger_glow - delta * 2.0)
			freeze_timer = maxf(0.0, freeze_timer - delta)

	# Update explosions
	var live_exp : Array = []
	for ex in explosions:
		ex["life"] -= delta
		if ex["life"] > 0.0: live_exp.append(ex)
	explosions = live_exp

	# Update debris
	var live_deb : Array = []
	for db in debris:
		db["pos"]  += db["vel"] * delta * 60.0
		db["vel"]  *= 0.92
		db["life"] -= delta
		if db["life"] > 0.0: live_deb.append(db)
	debris = live_deb

	# Update popups
	var live_pop : Array = []
	for pop in popups:
		pop["life"] -= delta
		if pop["life"] > 0.0: live_pop.append(pop)
	popups = live_pop

	# Update announcements
	var live_ann : Array = []
	for ann in announcements:
		ann["life"] -= delta
		if ann["life"] > 0.0: live_ann.append(ann)
	announcements = live_ann

	queue_redraw()

# ── Input ──────────────────────────────────────────────────────────────────────
func _input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed): return
	var kev := event as InputEventKey
	var start_keys := [KEY_UP,KEY_DOWN,KEY_LEFT,KEY_RIGHT,
					   KEY_W,KEY_A,KEY_S,KEY_D,KEY_SPACE,KEY_ENTER]

	if game_state in [State.MENU, State.DEAD]:
		if kev.keycode in start_keys:
			if game_state == State.DEAD and death_timer < 1.5: return
			_start_game(); return

	if game_state == State.PLAYING:
		match kev.keycode:
			KEY_UP,    KEY_W: if p_dir.y !=  1: p_next_dir = Vector2i( 0,-1)
			KEY_DOWN,  KEY_S: if p_dir.y != -1: p_next_dir = Vector2i( 0, 1)
			KEY_LEFT,  KEY_A: if p_dir.x !=  1: p_next_dir = Vector2i(-1, 0)
			KEY_RIGHT, KEY_D: if p_dir.x != -1: p_next_dir = Vector2i( 1, 0)

# ── Game lifecycle ─────────────────────────────────────────────────────────────
func _start_game() -> void:
	score              = 0
	p_pos              = Vector2i(COLS / 2, ROWS / 2)
	p_dir              = Vector2i(1, 0)
	p_next_dir         = Vector2i(1, 0)
	p_trail            = []
	p_max_trail        = 12
	p_alive            = true
	p_eat_flash        = 0.0
	p_grace            = GRACE_SEC
	combo              = 1
	combo_timer        = 0.0
	freeze_timer       = 0.0
	void_list          = []
	star_data          = []
	explosions         = []
	debris             = []
	popups             = []
	announcements      = []
	milestones_hit     = []
	move_accum         = 0.0
	death_timer        = 0.0
	game_time          = 0.0
	survival_tick      = 0.0
	survival_milestone = 0.0
	danger_glow        = 0.0
	shake_power        = 0.0

	_spawn_void(VoidType.SEEKER)
	for _i in 3: _spawn_star()
	game_state = State.PLAYING

func _kill_player() -> void:
	if not p_alive or p_grace > 0.0: return
	p_alive    = false
	game_state = State.DEAD
	death_timer = 0.0
	_shake(18.0)

	# Spawn debris from trail
	for seg in p_trail:
		var sp := _g2p(seg)
		for _i in 5:
			var angle := randf() * TAU
			var spd   := randf_range(1.5, 5.0)
			debris.append({
				"pos":      sp + Vector2(randf_range(-6,6), randf_range(-6,6)),
				"vel":      Vector2(cos(angle), sin(angle)) * spd,
				"life":     randf_range(0.4, 1.4),
				"max_life": 1.4,
				"col":      Color(0.0, randf_range(0.6,1.0), randf_range(0.7,1.0))
			})
	# Extra burst from player position
	var pp := _g2p(p_pos)
	for _i in 20:
		var angle := randf() * TAU
		var spd   := randf_range(3.0, 9.0)
		debris.append({
			"pos":      pp,
			"vel":      Vector2(cos(angle), sin(angle)) * spd,
			"life":     randf_range(0.5, 1.8),
			"max_life": 1.8,
			"col":      Color(1.0, randf_range(0.8,1.0), randf_range(0.5,1.0))
		})

	if score > best_score:
		best_score = score
		_save_best()

# ── Grid step ──────────────────────────────────────────────────────────────────
func _step() -> void:
	p_dir = p_next_dir
	var nx := p_pos.x + p_dir.x
	var ny := p_pos.y + p_dir.y

	if nx < 0 or nx >= COLS or ny < 0 or ny >= ROWS:
		_kill_player(); return

	var np := Vector2i(nx, ny)
	for seg: Vector2i in p_trail:
		if seg == np: _kill_player(); return

	# Check star collection
	for i in star_data.size():
		if star_data[i]["pos"] == np:
			_eat_star(i, np); break

	p_trail.push_front(p_pos)
	while p_trail.size() > p_max_trail:
		p_trail.pop_back()
	p_pos = np

# ── Star spawning ──────────────────────────────────────────────────────────────
func _spawn_star() -> void:
	var pos := Vector2i.ZERO
	var occupied := []
	for sd in star_data: occupied.append(sd["pos"])
	for _try in 60:
		pos = Vector2i(randi_range(1, COLS - 2), randi_range(1, ROWS - 2))
		if pos != p_pos and not p_trail.has(pos) and not occupied.has(pos):
			break

	# Star type weighting
	var roll  := randf()
	var stype := StarType.REGULAR
	if roll < 0.10:
		stype = StarType.NOVA
	elif roll < 0.25:
		stype = StarType.FREEZE

	star_data.append({"pos": pos, "age": randf() * TAU, "type": stype})

# ── Star collection ────────────────────────────────────────────────────────────
func _eat_star(idx: int, pos: Vector2i) -> void:
	var sd    := star_data[idx] as Dictionary
	var stype : StarType = sd["type"]
	star_data.remove_at(idx)

	var pixel_pos := _g2p(pos)
	p_eat_flash   = 1.0

	match stype:
		StarType.REGULAR:
			_collect_regular(pos, pixel_pos)

		StarType.FREEZE:
			_collect_freeze(pixel_pos)

		StarType.NOVA:
			_collect_nova(pos, pixel_pos)

	_spawn_star()
	if score > 0 and score % 50 == 0:
		_schedule_void()
	if score > 0 and score % 30 == 0:
		p_max_trail = mini(35, p_max_trail + 2)

func _collect_regular(pos: Vector2i, pixel_pos: Vector2) -> void:
	# Risk bonus
	var risk := 0
	for v in void_list:
		if v["active"] and (v["pos"] as Vector2).distance_to(pixel_pos) < 80.0:
			risk += 5

	# Combo
	combo = mini(combo + 1, COMBO_MAX) if combo_timer > 0.0 else 1
	combo_timer = COMBO_WINDOW

	var pts := (10 + risk) * combo
	score   += pts

	for _i in mini(4, p_trail.size()): p_trail.pop_back()

	var label := "+%d" % pts if combo == 1 else "+%d  x%d" % [pts, combo]
	popups.append({"pos": pixel_pos + Vector2(-24, -14), "text": label,
		"life": 1.0, "color": Color(1.0, 0.87, 0.2) if combo == 1 else Color(1.0, 0.55, 0.1),
		"size": 16 if combo == 1 else 21})
	if risk > 0:
		popups.append({"pos": pixel_pos + Vector2(-24, 4), "text": "RISKY +%d" % risk,
			"life": 0.8, "color": Color(1.0, 0.3, 0.3), "size": 13})

	_shake(3.0)

func _collect_freeze(pixel_pos: Vector2) -> void:
	freeze_timer = FREEZE_DUR
	score       += 15
	_shake(6.0)

	announcements.append({"text": "❄  FREEZE  ❄",
		"life": 2.5, "color": Color(0.4, 0.9, 1.0)})
	popups.append({"pos": pixel_pos + Vector2(-20, -14), "text": "+15  ❄",
		"life": 1.2, "color": Color(0.4, 0.9, 1.0), "size": 20})

	# Small explosion for feedback
	explosions.append({"pos": pixel_pos, "radius": 0.0,
		"max_radius": 60.0, "life": 0.5, "max_life": 0.5,
		"color": Color(0.3, 0.85, 1.0)})

func _collect_nova(pos: Vector2i, pixel_pos: Vector2) -> void:
	_shake(14.0)
	score += 25

	# Big shockwave ring
	explosions.append({"pos": pixel_pos, "radius": 0.0,
		"max_radius": NOVA_RADIUS, "life": 0.7, "max_life": 0.7,
		"color": Color(1.0, 0.55, 0.1)})
	# Inner ring
	explosions.append({"pos": pixel_pos, "radius": 0.0,
		"max_radius": NOVA_RADIUS * 0.55, "life": 0.5, "max_life": 0.5,
		"color": Color(1.0, 0.85, 0.3)})

	announcements.append({"text": "✦  NOVA  ✦",
		"life": 2.5, "color": Color(1.0, 0.6, 0.1)})
	popups.append({"pos": pixel_pos + Vector2(-20, -14), "text": "+25  ✦",
		"life": 1.2, "color": Color(1.0, 0.65, 0.1), "size": 20})

	# Push all voids away from nova point
	for v in void_list:
		if v["active"]:
			var away : Vector2 = (v["pos"] as Vector2) - pixel_pos
			var d    : float   = away.length()
			if d < NOVA_RADIUS + 40.0:
				var force := (1.0 - clampf(d / (NOVA_RADIUS + 40.0), 0.0, 1.0)) * 18.0
				v["vel"] += away.normalized() * force

	# Clear trail segments inside nova radius
	var cleared := 0
	var kept    : Array = []
	for seg: Vector2i in p_trail:
		if _g2p(seg).distance_to(pixel_pos) < NOVA_RADIUS:
			cleared += 1
		else:
			kept.append(seg)
	p_trail = kept
	if cleared > 0:
		score += cleared   # small bonus per segment cleared
		popups.append({"pos": pixel_pos + Vector2(-24, 10),
			"text": "CLEARED %d" % cleared,
			"life": 0.9, "color": Color(1.0, 0.75, 0.35), "size": 13})

	# Nova debris burst
	for _i in 30:
		var angle := randf() * TAU
		var spd   := randf_range(2.0, 7.0)
		debris.append({
			"pos":      pixel_pos,
			"vel":      Vector2(cos(angle), sin(angle)) * spd,
			"life":     randf_range(0.3, 0.9),
			"max_life": 0.9,
			"col":      Color(randf_range(0.8,1.0), randf_range(0.4,0.7), 0.1)
		})

# ── Void spawning ──────────────────────────────────────────────────────────────
func _pick_spawn_pos() -> Vector2:
	var pp := _g2p(p_pos)
	var pos := Vector2.ZERO
	for _try in 60:
		if randf() < 0.5:
			pos.x = (1 if randf() < 0.5 else COLS-2) * CELL + CELL*0.5
			pos.y = randi_range(0, ROWS-1) * CELL + CELL*0.5
		else:
			pos.x = randi_range(0, COLS-1) * CELL + CELL*0.5
			pos.y = (1 if randf() < 0.5 else ROWS-2) * CELL + CELL*0.5
		if pos.distance_to(pp) > 160.0: break
	return pos

func _make_void(type: VoidType, active: bool) -> Dictionary:
	var pos := _pick_spawn_pos()
	return {
		"pos":          pos,
		"vel":          Vector2((randf()-0.5)*0.6, (randf()-0.5)*0.6),
		"spin":         randf() * TAU,
		"spin_rate":    (randf()-0.5) * 0.045,
		"radius":       18.0 if type != VoidType.DRIFTER else 22.0,
		"hunger":       0.0,
		"type":         type,
		"age":          0.0,
		"active":       active,
		"warn_timer":   0.0 if active else WARN_DURATION,
		"wander_target": pos,
		"wander_timer":  0.0,
	}

func _spawn_void(type: VoidType) -> void:
	void_list.append(_make_void(type, true))

func _schedule_void() -> void:
	var type := VoidType.SEEKER
	var roll := randf()
	if game_time >= 60.0 and roll < 0.35:   type = VoidType.AMBUSHER
	elif game_time >= 30.0 and roll < 0.50: type = VoidType.DRIFTER
	void_list.append(_make_void(type, false))

# ── Difficulty milestones ──────────────────────────────────────────────────────
func _check_milestones() -> void:
	for t in [30, 60, 120, 180]:
		if game_time >= float(t) and not milestones_hit.has(t):
			milestones_hit.append(t)
			_trigger_milestone(t)

func _trigger_milestone(s: int) -> void:
	_shake(10.0)
	match s:
		30:  announcements.append({"text":"WANDERERS APPROACH","life":3.0,"color":Color(0.5,0.4,1.0)}); _schedule_void()
		60:  announcements.append({"text":"HUNTERS DETECTED",  "life":3.0,"color":Color(1.0,0.3,0.3)}); _schedule_void()
		120: announcements.append({"text":"THE VOID AWAKENS",  "life":3.5,"color":Color(1.0,0.1,0.5)}); _schedule_void(); _schedule_void()
		180: announcements.append({"text":"NO ESCAPE",         "life":3.5,"color":Color(1.0,0.0,0.0)}); _schedule_void()

# ── Void update ────────────────────────────────────────────────────────────────
func _update_voids(delta: float) -> void:
	var pp         := _g2p(p_pos)
	var time_scale := 1.0 + game_time / 150.0
	var freeze_scale := 0.15 if freeze_timer > 0.0 else 1.0

	for v in void_list:
		v["age"] += delta

		if not v["active"]:
			v["warn_timer"] -= delta
			if v["warn_timer"] <= 0.0: v["active"] = true
			continue

		var birth : float    = minf(1.0, v["age"] / 12.0)
		var type  : VoidType = v["type"]
		var spd_scale : float = birth * time_scale * freeze_scale

		match type:
			VoidType.SEEKER:
				var spd := (0.18 + void_list.size() * 0.018) * spd_scale
				var to_p : Vector2 = pp - v["pos"]
				if to_p.length() > 0.1: v["vel"] += to_p.normalized() * spd * 0.09

			VoidType.DRIFTER:
				v["wander_timer"] -= delta
				if v["wander_timer"] <= 0.0:
					v["wander_timer"] = randf_range(1.5, 3.5)
					v["wander_target"] = pp + Vector2(randf_range(-60,60), randf_range(-60,60)) \
						if randf() < 0.30 \
						else Vector2(randf_range(30.0, W-30.0), randf_range(30.0, H-30.0))
				var spd := (0.10 + void_list.size() * 0.010) * spd_scale
				var to_w : Vector2 = v["wander_target"] - v["pos"]
				if to_w.length() > 0.1: v["vel"] += to_w.normalized() * spd * 0.07
				v["vel"] += (pp - v["pos"]).normalized() * spd * 0.015

			VoidType.AMBUSHER:
				var predicted := _g2p(p_pos + p_dir * 5)
				var to_pred   : Vector2 = predicted - v["pos"]
				var spd := (0.24 + void_list.size() * 0.022) * spd_scale
				if to_pred.length() > 12.0: v["vel"] += to_pred.normalized() * spd * 0.11
				else:                        v["vel"] *= 0.88

		v["vel"] *= 0.965
		v["pos"] += v["vel"]
		v["spin"] += v["spin_rate"]
		v["hunger"] = maxf(0.0, v["hunger"] - delta * 0.6)

		# Wall bounce
		var r : float = v["radius"]
		if v["pos"].x < r:     v["pos"].x = r;     v["vel"].x =  absf(v["vel"].x)
		if v["pos"].x > W - r: v["pos"].x = W - r; v["vel"].x = -absf(v["vel"].x)
		if v["pos"].y < r:     v["pos"].y = r;     v["vel"].y =  absf(v["vel"].y)
		if v["pos"].y > H - r: v["pos"].y = H - r; v["vel"].y = -absf(v["vel"].y)

		# Kill player
		if p_alive and p_grace <= 0.0:
			if (v["pos"] as Vector2).distance_to(pp) < r + 6.0:
				_kill_player(); return

		# Eat trail
		var eat_r : float = r + (6.0 if type == VoidType.DRIFTER else 4.0)
		var surviving : Array = []
		var ate_any := false
		for seg: Vector2i in p_trail:
			var sp := _g2p(seg)
			if (v["pos"] as Vector2).distance_to(sp) < eat_r:
				v["hunger"] = minf(3.0, v["hunger"] + 1.0)
				score       = maxi(0, score - 2)
				ate_any     = true
			else:
				surviving.append(seg)
		p_trail = surviving
		if ate_any:
			_shake(4.0)

# ── Utility ────────────────────────────────────────────────────────────────────
func _g2p(g: Vector2i) -> Vector2:
	return Vector2(g.x * CELL + CELL * 0.5, g.y * CELL + CELL * 0.5)

# ══════════════════════════════════════════════════════════════════════════════
#  D R A W I N G
# ══════════════════════════════════════════════════════════════════════════════
func _draw() -> void:
	_draw_bg()
	_draw_vignette()

	match game_state:
		State.MENU:
			_draw_menu()
		State.PLAYING, State.DEAD:
			_draw_trail()
			_draw_stars()
			_draw_void_warnings()
			_draw_explosions()
			_draw_voids()
			_draw_player()
			_draw_debris()
			_draw_popups()
			_draw_hud()
			_draw_announcements()
			if danger_glow > 0.01: _draw_danger_edge()
			if freeze_timer > 0.0: _draw_freeze_overlay()
			if game_state == State.DEAD: _draw_death()

# ── Background ─────────────────────────────────────────────────────────────────
func _draw_bg() -> void:
	draw_rect(Rect2(0, 0, W, H), Color(0.020, 0.020, 0.030))
	var gc := Color(0.0, 0.23, 0.31, 0.17)
	for x in range(0, W + 1, CELL):
		draw_line(Vector2(x, 0), Vector2(x, H), gc, 0.5)
	for y in range(0, H + 1, CELL):
		draw_line(Vector2(0, y), Vector2(W, y), gc, 0.5)
	for p in bg_particles:
		var bright: float = 0.18 + p["b"] * 0.38 * (0.7 + 0.3 * sin(game_time * 0.8 + p["b"] * 10.0))
		draw_circle(Vector2(p["x"], p["y"]), p["r"], Color(0.38, 0.76, 1.0, bright * 0.5))

# ── Vignette ───────────────────────────────────────────────────────────────────
func _draw_vignette() -> void:
	# Draw darkened rectangles along each edge (cheap radial gradient fake)
	var depth := 80.0
	for i in range(int(depth)):
		var a := float(i) / depth
		var fade := (1.0 - a) * (1.0 - a) * 0.45
		draw_rect(Rect2(0,        i,       W, 1), Color(0,0,0, fade))
		draw_rect(Rect2(0,        H-1-i,   W, 1), Color(0,0,0, fade))
		draw_rect(Rect2(i,        0,       1, H), Color(0,0,0, fade))
		draw_rect(Rect2(W-1-i,    0,       1, H), Color(0,0,0, fade))

# ── Freeze overlay ─────────────────────────────────────────────────────────────
func _draw_freeze_overlay() -> void:
	var a    := (freeze_timer / FREEZE_DUR) * 0.12
	var edge := 6.0
	draw_rect(Rect2(0, 0, W, edge),       Color(0.3, 0.85, 1.0, a))
	draw_rect(Rect2(0, H-edge, W, edge),  Color(0.3, 0.85, 1.0, a))
	draw_rect(Rect2(0, 0, edge, H),       Color(0.3, 0.85, 1.0, a))
	draw_rect(Rect2(W-edge, 0, edge, H),  Color(0.3, 0.85, 1.0, a))
	# Timer bar across top
	var bar := (freeze_timer / FREEZE_DUR) * W
	draw_rect(Rect2(0, 0, bar, 3), Color(0.3, 0.9, 1.0, 0.8))

# ── Danger edge ────────────────────────────────────────────────────────────────
func _draw_danger_edge() -> void:
	var a  := danger_glow * 0.45
	var pw := 22.0 * danger_glow
	var c  := Color(1.0, 0.1, 0.3, a)
	draw_rect(Rect2(0, 0, W, pw), c);        draw_rect(Rect2(0, H-pw, W, pw), c)
	draw_rect(Rect2(0, 0, pw, H), c);        draw_rect(Rect2(W-pw, 0, pw, H), c)

# ── Trail ──────────────────────────────────────────────────────────────────────
func _draw_trail() -> void:
	var n := p_trail.size()
	for i in n:
		var seg  : Vector2i = p_trail[i]
		var life : float    = 1.0 - float(i) / float(maxi(p_max_trail, 1))
		var frozen_tint := 0.4 if freeze_timer > 0.0 else 0.0
		var col  : Color    = Color(
			life * 0.12 + frozen_tint * 0.2,
			0.57 + life * 0.43 - frozen_tint * 0.1,
			0.76 + life * 0.24 + frozen_tint * 0.2,
			0.13 + life * 0.73)
		var ctr  : Vector2  = _g2p(seg)
		var s    : float    = CELL - 4.0
		draw_rect(Rect2(ctr.x - s*0.5, ctr.y - s*0.5, s, s), col)
		if life > 0.65:
			var hl := (life - 0.65) / 0.35 * 0.32
			draw_rect(Rect2(ctr.x - s*0.5+2, ctr.y - s*0.5+2, s-4, s-4),
				Color(0.55, 1.0, 1.0, hl))

# ── Stars ──────────────────────────────────────────────────────────────────────
func _draw_stars() -> void:
	for sd in star_data:
		var gpos  : Vector2i = sd["pos"]
		var age   : float    = sd["age"]
		var stype : StarType = sd["type"]
		var tw    : float    = sin(age * 2.8) * 0.3 + 0.7
		var sp    : Vector2  = _g2p(gpos)

		match stype:
			StarType.REGULAR:
				var r := 4.5 + tw * 3.0
				for ring in range(3, 0, -1):
					draw_circle(sp, r * (1.0 + ring * 0.5), Color(1.0, 0.87, 0.2, 0.03 * tw * ring))
				draw_colored_polygon(_star_pts(sp, 5, r, r*0.42), Color(1.0, 0.93, 0.35, 0.88 + tw*0.12))

			StarType.FREEZE:
				var r := 5.0 + tw * 2.5
				# Cyan glow
				for ring in range(3, 0, -1):
					draw_circle(sp, r * (1.0 + ring * 0.55), Color(0.3, 0.85, 1.0, 0.04 * tw * ring))
				# 6-point snowflake
				draw_colored_polygon(_star_pts(sp, 6, r, r*0.38), Color(0.5, 0.95, 1.0, 0.9 + tw*0.1))
				# Inner sparkle
				draw_circle(sp, r*0.3, Color(1.0, 1.0, 1.0, 0.7 * tw))

			StarType.NOVA:
				var r := 5.5 + tw * 3.5
				# Orange-red glow
				for ring in range(4, 0, -1):
					draw_circle(sp, r * (1.0 + ring * 0.6), Color(1.0, 0.55, 0.1, 0.04 * tw * ring))
				# 8-point spiky star
				draw_colored_polygon(_star_pts(sp, 8, r, r*0.30), Color(1.0, 0.65, 0.15, 0.9 + tw*0.1))
				draw_circle(sp, r*0.35, Color(1.0, 0.9, 0.5, 0.8 * tw))

func _star_pts(center: Vector2, points: int, outer_r: float, inner_r: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for k in points * 2:
		var angle := -PI * 0.5 + k * TAU / float(points * 2)
		var rad   := outer_r if k % 2 == 0 else inner_r
		pts.append(center + Vector2(cos(angle), sin(angle)) * rad)
	return pts

# ── Void warnings ──────────────────────────────────────────────────────────────
func _draw_void_warnings() -> void:
	for v in void_list:
		if v["active"]: continue
		var progress : float = 1.0 - v["warn_timer"] / WARN_DURATION
		var pulse    : float = sin(game_time * 8.0) * 0.4 + 0.6
		var r        : float = (v["radius"] as float) * (1.5 + pulse * 0.5)
		var col : Color
		match v["type"] as VoidType:
			VoidType.SEEKER:   col = Color(0.7, 0.0, 1.0, 0.35 * progress * pulse)
			VoidType.DRIFTER:  col = Color(0.3, 0.2, 1.0, 0.30 * progress * pulse)
			VoidType.AMBUSHER: col = Color(1.0, 0.2, 0.1, 0.40 * progress * pulse)
		draw_arc(v["pos"], r, 0.0, TAU, 32, col, 2.0)
		draw_arc(v["pos"], r * 0.6, 0.0, TAU, 24, Color(col.r, col.g, col.b, col.a * 0.5), 1.0)

# ── Explosions ─────────────────────────────────────────────────────────────────
func _draw_explosions() -> void:
	for ex in explosions:
		var t   : float  = 1.0 - ex["life"] / ex["max_life"]
		var r   : float  = ex["max_radius"] * t
		var a   : float  = (1.0 - t) * 0.85
		var col : Color  = ex["color"]
		draw_arc(ex["pos"], r, 0.0, TAU, 48,
			Color(col.r, col.g, col.b, a), maxf(0.5, 3.0 * (1.0 - t)))
		if r > 10.0:
			draw_arc(ex["pos"], r * 0.55, 0.0, TAU, 36,
				Color(col.r * 0.8 + 0.2, col.g * 0.8 + 0.2, col.b * 0.8 + 0.2, a * 0.5), 1.5)

# ── Voids ──────────────────────────────────────────────────────────────────────
func _draw_voids() -> void:
	for v in void_list:
		if not v["active"]: continue
		var pos    : Vector2  = v["pos"]
		var r      : float    = v["radius"]
		var spin   : float    = v["spin"]
		var hunger : float    = v["hunger"]
		var type   : VoidType = v["type"]
		var birth  : float    = minf(1.0, v["age"] / 2.0)
		var frozen : bool     = freeze_timer > 0.0

		# Color theme
		var main_col : Color
		if frozen:
			main_col = Color(0.3, 0.7, 1.0)
		else:
			match type:
				VoidType.SEEKER:   main_col = Color(0.78, 0.18, 1.00)
				VoidType.DRIFTER:  main_col = Color(0.30, 0.22, 1.00)
				VoidType.AMBUSHER: main_col = Color(1.00, 0.28, 0.10)

		# Outer rings
		for ring in range(4, 0, -1):
			var rr := r * (1.35 + ring * 0.6) + hunger * 4.0
			var a  := (0.05 + hunger * 0.06) / float(ring) * birth
			draw_arc(pos, rr, 0.0, TAU, 40, Color(main_col.r, main_col.g, main_col.b, a), 1.5)

		# Frozen cracks / ice effect
		if frozen:
			for arm in range(6):
				var angle := spin * 0.3 + arm * TAU / 6.0
				var inner := pos + Vector2(cos(angle), sin(angle)) * r
				var outer := pos + Vector2(cos(angle), sin(angle)) * (r * 2.0)
				draw_line(inner, outer, Color(0.5, 0.9, 1.0, 0.4 * birth), 1.0)

		# Personality details (only when not frozen)
		elif type == VoidType.SEEKER:
			for arm in range(3):
				var angle := spin + arm * TAU / 3.0
				draw_arc(pos, r + r*0.8, angle - 0.20, angle + 0.20, 10,
					Color(main_col.r, main_col.g, main_col.b, (0.65 + hunger*0.25)*birth), 2.0+hunger)
				draw_circle(pos + Vector2(cos(angle), sin(angle)) * r * 2.0,
					2.5 + hunger, Color(0.9, 0.5, 1.0, 0.5 * birth))

		elif type == VoidType.DRIFTER:
			for ring2 in range(3):
				var rr2 := r * (0.8 + ring2*0.35 + sin(spin*0.5 + ring2)*0.15)
				draw_arc(pos, rr2, spin + ring2*0.8, spin + ring2*0.8 + TAU*0.6,
					20, Color(main_col.r, main_col.g, main_col.b, 0.18*birth), 1.2)

		elif type == VoidType.AMBUSHER:
			for arm in range(4):
				var angle := spin * 0.4 + arm * TAU / 4.0
				var inner := pos + Vector2(cos(angle), sin(angle)) * (r + 2.0)
				var outer := pos + Vector2(cos(angle), sin(angle)) * (r + r*0.6 + hunger*2.0)
				draw_line(inner, outer, Color(main_col.r, main_col.g, main_col.b, (0.8+hunger*0.2)*birth), 2.0)
			var predicted := _g2p(p_pos + p_dir * 5)
			var to_pred   := (predicted - pos).normalized() * (r + 4.0)
			draw_line(pos + to_pred, pos + to_pred * 2.2, Color(1.0, 0.4, 0.1, 0.35*birth), 1.0)

		# Dark core
		draw_circle(pos, r,        Color(0.00, 0.00, 0.00, 0.97*birth))
		draw_circle(pos, r * 0.62, Color(0.07, 0.00, 0.13, 1.00*birth))
		draw_circle(pos, r * 0.28, Color(main_col.r*0.3, main_col.g*0.1, main_col.b*0.5, birth))

# ── Player ─────────────────────────────────────────────────────────────────────
func _draw_player() -> void:
	if not p_alive and fmod(death_timer * 9.0, 1.0) < 0.45: return
	var pp  := _g2p(p_pos)
	var eat := p_eat_flash

	if p_grace > 0.0:
		var shield_a := (p_grace / GRACE_SEC) * (sin(game_time * 10.0) * 0.25 + 0.5)
		draw_arc(pp, 18.0 + glow_pulse * 3.0, 0.0, TAU, 40, Color(0.3, 1.0, 0.6, shield_a), 2.0)

	for ring in range(5, 0, -1):
		var rr := 7.0 + ring * 4.5 + glow_pulse * 4.0 + eat * 8.0
		draw_circle(pp, rr, Color(0.0, 1.0, 1.0, 0.05 * float(6-ring)/5.0 + eat*0.06))

	var tip  := pp + Vector2(p_dir.x, p_dir.y) * 10.5
	var perp := Vector2(-p_dir.y, p_dir.x) * 3.5
	draw_colored_polygon(PackedVector2Array([tip, pp + perp*0.6, pp - perp*0.6]),
		Color(0.5, 1.0, 1.0, 0.55))
	draw_circle(pp, 5.2 + glow_pulse*1.5 + eat*2.0, Color(1.0, 1.0, 1.0, 0.96))
	draw_circle(pp, 2.4, Color(0.6, 1.0, 1.0, 1.0))

# ── Debris ──────────────────────────────────────────────────────────────────────
func _draw_debris() -> void:
	for db in debris:
		var life_f: float = db["life"] / db["max_life"]
		var col    : Color = db["col"]
		col.a = life_f * life_f
		draw_circle(db["pos"], 3.0 * life_f + 1.0, col)

# ── Popups ─────────────────────────────────────────────────────────────────────
func _draw_popups() -> void:
	for pop in popups:
		var life  : float = pop["life"]
		var rise  : float = (1.0 - life) * 30.0
		var alpha : float = life if life > 0.5 else life * 2.0
		var col   : Color = pop["color"]
		col.a = alpha
		draw_string(font, pop["pos"] - Vector2(0, rise), pop["text"],
			HORIZONTAL_ALIGNMENT_LEFT, -1, pop["size"], col)

# ── Announcements ──────────────────────────────────────────────────────────────
func _draw_announcements() -> void:
	for ann in announcements:
		var life  : float = ann["life"]
		var alpha : float = minf(1.0, life * 2.0)
		var col   : Color = ann["color"]
		col.a = alpha
		for layer in range(3, 0, -1):
			draw_string(font, Vector2(0, H*0.5 - 110), ann["text"],
				HORIZONTAL_ALIGNMENT_CENTER, W, 27+layer,
				Color(col.r, col.g, col.b, 0.07 * float(4-layer) * alpha))
		draw_string(font, Vector2(0, H*0.5 - 110), ann["text"],
			HORIZONTAL_ALIGNMENT_CENTER, W, 27, col)

# ── HUD ────────────────────────────────────────────────────────────────────────
func _draw_hud() -> void:
	draw_string(font, Vector2(14, 22), "SCORE  %d" % score,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0, 1, 1, 0.85))
	draw_string(font, Vector2(14, 42), "BEST   %d" % best_score,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0, 1, 1, 0.5))
	draw_string(font, Vector2(14, 62), "VOIDS  %d" % void_list.filter(
		func(v): return v["active"]).size(),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.7, 0.2, 1.0, 0.8))

	var mins := int(game_time) / 60
	var secs := int(game_time) % 60
	draw_string(font, Vector2(W - 90, 22), "%02d:%02d" % [mins, secs],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0, 1, 1, 0.45))

	if combo > 1 and combo_timer > 0.0:
		var bar_w := 80.0 * (combo_timer / COMBO_WINDOW)
		draw_rect(Rect2(W-94, 36, 82, 8), Color(0.15, 0.08, 0.0, 0.6))
		draw_rect(Rect2(W-94, 36, bar_w, 8), Color(1.0, 0.55, 0.1, 0.85))
		draw_string(font, Vector2(W-94, 58), "COMBO  x%d" % combo,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1.0, 0.6, 0.1, 0.92))

	if freeze_timer > 0.0:
		draw_string(font, Vector2(W-94, 76), "FREEZE  %.1fs" % freeze_timer,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.4, 0.9, 1.0, 0.9))

	# Void type legend
	var legend_y := H - 46.0
	for entry in [["SEEKER", Color(0.78,0.18,1.00), VoidType.SEEKER],
				  ["DRIFTER", Color(0.30,0.22,1.00), VoidType.DRIFTER],
				  ["AMBUSHER", Color(1.00,0.28,0.10), VoidType.AMBUSHER]]:
		var count := void_list.filter(func(v): return v["active"] and v["type"] == entry[2]).size()
		if count > 0:
			draw_string(font, Vector2(W-90, legend_y), "%s  %d" % [entry[0], count],
				HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color((entry[1] as Color).r, (entry[1] as Color).g, (entry[1] as Color).b, 0.55))
			legend_y -= 14.0

	draw_string(font, Vector2(12, H-8), "trail %d / %d" % [p_trail.size(), p_max_trail],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0, 1, 1, 0.28))

# ── Menu ───────────────────────────────────────────────────────────────────────
func _draw_menu() -> void:
	var pulse := 0.82 + 0.18 * sin(game_time * 2.8)
	var cy    := H * 0.5
	for layer in range(3, 0, -1):
		draw_string(font, Vector2(0, cy-72), "VOID WALKER",
			HORIZONTAL_ALIGNMENT_CENTER, W, 60+layer*2, Color(0,1,1, 0.07*float(4-layer)*pulse))
	draw_string(font, Vector2(0, cy-72), "VOID WALKER",
		HORIZONTAL_ALIGNMENT_CENTER, W, 60, Color(0,1,1,pulse))
	draw_string(font, Vector2(0, cy-16), "YOUR LIGHT TRAIL IS YOUR WEAPON",
		HORIZONTAL_ALIGNMENT_CENTER, W, 16, Color(0,1,1,0.57))
	draw_string(font, Vector2(0, cy+8), "AND YOUR PRISON",
		HORIZONTAL_ALIGNMENT_CENTER, W, 16, Color(0,1,1,0.44))
	draw_line(Vector2(W*0.25, cy+28), Vector2(W*0.75, cy+28), Color(0,1,1,0.18), 1.0)
	var tips := [
		["collect  ★  REGULAR  — erase trail, score, combo",  Color(1.0, 0.93, 0.35, 0.45)],
		["collect  ❄  FREEZE   — all voids slow for 4 s",     Color(0.4,  0.9,  1.0, 0.45)],
		["collect  ✦  NOVA     — shockwave pushes all voids",  Color(1.0,  0.65, 0.1, 0.45)],
		["3 void types unlock as you survive longer",          Color(0.8,  0.5,  1.0, 0.40)],
	]
	var ty := cy + 52.0
	for tip in tips:
		draw_string(font, Vector2(0, ty), tip[0], HORIZONTAL_ALIGNMENT_CENTER, W, 13, tip[1])
		ty += 21.0
	if fmod(game_time, 1.1) < 0.65:
		draw_string(font, Vector2(0, cy+158), "─  PRESS ANY ARROW KEY  ─",
			HORIZONTAL_ALIGNMENT_CENTER, W, 19, Color(1,1,1,0.88))
	if best_score > 0:
		draw_string(font, Vector2(0, cy+188), "BEST  %d" % best_score,
			HORIZONTAL_ALIGNMENT_CENTER, W, 13, Color(1.0,0.87,0.2,0.65))

# ── Death ──────────────────────────────────────────────────────────────────────
func _draw_death() -> void:
	draw_rect(Rect2(0,0,W,H), Color(0,0,0, minf(0.82, death_timer*1.2)))
	if death_timer < 0.35: return
	var fade := minf(1.0, (death_timer - 0.35) / 0.6)
	var cy   := H * 0.5
	for layer in range(3, 0, -1):
		draw_string(font, Vector2(0, cy-52), "CONSUMED",
			HORIZONTAL_ALIGNMENT_CENTER, W, 58+layer*2, Color(1,0.02,0.27, 0.06*float(4-layer)*fade))
	draw_string(font, Vector2(0, cy-52), "CONSUMED",
		HORIZONTAL_ALIGNMENT_CENTER, W, 58, Color(1.0, 0.05, 0.30, fade))
	draw_string(font, Vector2(0, cy+12), "SCORE  %d" % score,
		HORIZONTAL_ALIGNMENT_CENTER, W, 24, Color(1,1,1, 0.88*fade))
	var mins := int(game_time) / 60
	var secs := int(game_time) % 60
	draw_string(font, Vector2(0, cy+40), "SURVIVED  %02d:%02d" % [mins, secs],
		HORIZONTAL_ALIGNMENT_CENTER, W, 15, Color(0,1,1, 0.6*fade))
	if score >= best_score and score > 0:
		draw_string(font, Vector2(0, cy+64), "✦  NEW BEST  ✦",
			HORIZONTAL_ALIGNMENT_CENTER, W, 16, Color(1.0,0.87,0.2, fade))
	if death_timer > 1.5 and fmod(game_time, 1.05) < 0.60:
		draw_string(font, Vector2(0, cy+92), "─  PRESS ANY KEY TO RETRY  ─",
			HORIZONTAL_ALIGNMENT_CENTER, W, 16, Color(1,1,1, 0.72*fade))
