## ═══════════════════════════════════════════════════════════════
##  V O I D   W A L K E R  —  Main.gd  (v2)
##
##  Improvements over v1:
##    ∙ 3 void personalities: Seeker / Drifter / Ambusher
##    ∙ Void birth ramp  (spawns slow, accelerates over ~12s)
##    ∙ Pre-spawn warning pulse before void becomes active
##    ∙ Star combo multiplier  (up to 8×, 2.5s window)
##    ∙ Risk multiplier  (bonus pts when a void is near you)
##    ∙ Difficulty milestones at 30 / 60 / 120 s
##    ∙ 3-second grace period at game start
##    ∙ Screen-edge danger glow when voids are close
##    ∙ Centered announcement banners for milestone events
## ═══════════════════════════════════════════════════════════════
extends Node2D

# ── Constants ────────────────────────────────────────────────────────────────
const CELL         := 20
const COLS         := 40
const ROWS         := 30
const W            := COLS * CELL      # 800
const H            := ROWS * CELL      # 600
const MOVE_SEC     := 0.13
const COMBO_WINDOW := 2.5              # seconds to chain next star
const COMBO_MAX    := 8
const WARN_DURATION := 1.8             # seconds a void pulses before becoming active
const GRACE_SEC    := 3.0              # invincible at round start

# ── Void personality enum ────────────────────────────────────────────────────
enum VoidType { SEEKER, DRIFTER, AMBUSHER }

# ── Game state ────────────────────────────────────────────────────────────────
enum State { MENU, PLAYING, DEAD }
var game_state : State = State.MENU
var score      : int   = 0
var best_score : int   = 0

# ── Player ────────────────────────────────────────────────────────────────────
var p_pos        : Vector2i = Vector2i(COLS / 2, ROWS / 2)
var p_dir        : Vector2i = Vector2i(1, 0)
var p_next_dir   : Vector2i = Vector2i(1, 0)
var p_trail      : Array    = []    # Array of Vector2i
var p_max_trail  : int      = 12
var p_alive      : bool     = true
var p_eat_flash  : float    = 0.0
var p_grace      : float    = 0.0   # countdown; player is invincible while > 0

# ── Combo ─────────────────────────────────────────────────────────────────────
var combo        : int   = 1
var combo_timer  : float = 0.0      # counts DOWN; combo breaks at 0

# ── Voids ─────────────────────────────────────────────────────────────────────
# Each void dict: {pos, vel, spin, spin_rate, radius, hunger,
#                  type, age, active, warn_timer,
#                  wander_target, wander_timer}   (drifter extras)
var void_list : Array = []

# ── Stars ─────────────────────────────────────────────────────────────────────
var star_list  : Array = []   # Array of Vector2i
var star_ages  : Array = []   # parallel float (twinkle phase)

# ── Score popups ──────────────────────────────────────────────────────────────
var popups        : Array = []   # {pos, text, life, color, size}
var announcements : Array = []   # {text, life, color}  — centered banners

# ── Timers / animation ────────────────────────────────────────────────────────
var move_accum  : float = 0.0
var game_time   : float = 0.0
var glow_pulse  : float = 0.0
var death_timer : float = 0.0
var danger_glow : float = 0.0   # screen-edge flash when a void is near

# ── Milestone tracking ────────────────────────────────────────────────────────
var milestones_hit : Array = []   # list of seconds-thresholds already triggered

# ── Font + bg particles ───────────────────────────────────────────────────────
var font         : Font
var bg_particles : Array = []

# ─────────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	font = ThemeDB.fallback_font
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

# ── Main loop ─────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	game_time  += delta
	glow_pulse  = sin(game_time * 6.0) * 0.5 + 0.5

	# drift background particles
	for p in bg_particles:
		p["x"] = fmod(p["x"] + p["drift"] + W, W)

	match game_state:
		State.PLAYING:
			# grace countdown
			p_grace = maxf(0.0, p_grace - delta)

			# combo decay
			if combo_timer > 0.0:
				combo_timer -= delta
				if combo_timer <= 0.0:
					combo = 1

			# grid tick
			move_accum += delta
			if move_accum >= MOVE_SEC:
				move_accum -= MOVE_SEC
				_step()

			_update_voids(delta)
			_check_milestones()

			# eat flash decay
			p_eat_flash = maxf(0.0, p_eat_flash - delta * 5.0)

			# star age tick
			for i in star_ages.size():
				star_ages[i] += delta

			# danger glow (nearest void proximity)
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

	# update popups
	var alive_pop : Array = []
	for pop in popups:
		pop["life"] -= delta
		if pop["life"] > 0.0: alive_pop.append(pop)
	popups = alive_pop

	# update announcements
	var alive_ann : Array = []
	for ann in announcements:
		ann["life"] -= delta
		if ann["life"] > 0.0: alive_ann.append(ann)
	announcements = alive_ann

	queue_redraw()

# ── Input ──────────────────────────────────────────────────────────────────────
func _input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed): return
	var kev := event as InputEventKey

	var action_keys := [KEY_UP,KEY_DOWN,KEY_LEFT,KEY_RIGHT,
						KEY_W,KEY_A,KEY_S,KEY_D,KEY_SPACE,KEY_ENTER]

	if game_state in [State.MENU, State.DEAD]:
		if kev.keycode in action_keys:
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
	score        = 0
	p_pos        = Vector2i(COLS / 2, ROWS / 2)
	p_dir        = Vector2i(1, 0)
	p_next_dir   = Vector2i(1, 0)
	p_trail      = []
	p_max_trail  = 12
	p_alive      = true
	p_eat_flash  = 0.0
	p_grace      = GRACE_SEC
	combo        = 1
	combo_timer  = 0.0
	void_list    = []
	star_list    = []
	star_ages    = []
	popups       = []
	announcements = []
	milestones_hit = []
	move_accum   = 0.0
	death_timer  = 0.0
	game_time    = 0.0
	danger_glow  = 0.0

	_spawn_void(VoidType.SEEKER)
	for _i in 3: _spawn_star()
	game_state = State.PLAYING

func _kill_player() -> void:
	if not p_alive or p_grace > 0.0: return
	p_alive = false
	game_state = State.DEAD
	death_timer = 0.0
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

	# Check star
	for i in star_list.size():
		if star_list[i] == np:
			_eat_star(i, np); break

	p_trail.push_front(p_pos)
	while p_trail.size() > p_max_trail:
		p_trail.pop_back()
	p_pos = np

# ── Star ───────────────────────────────────────────────────────────────────────
func _eat_star(idx: int, pos: Vector2i) -> void:
	star_list.remove_at(idx)
	star_ages.remove_at(idx)

	# Risk bonus: extra pts if a void is very close
	var pp := _g2p(pos)
	var risk_bonus := 0
	for v in void_list:
		if v["active"] and (v["pos"] as Vector2).distance_to(pp) < 80.0:
			risk_bonus += 5

	# Combo multiplier
	if combo_timer > 0.0:
		combo = mini(combo + 1, COMBO_MAX)
	else:
		combo = 1
	combo_timer = COMBO_WINDOW

	var pts := (10 + risk_bonus) * combo
	score += pts
	p_eat_flash = 1.0

	# Erase 4 oldest trail segments
	for _i in mini(4, p_trail.size()):
		p_trail.pop_back()

	# Build popup text
	var popup_text := "+%d" % pts
	if combo > 1:
		popup_text = "+%d  x%d" % [pts, combo]

	popups.append({
		"pos":   _g2p(pos) + Vector2(-28, -14),
		"text":  popup_text,
		"life":  1.0,
		"color": Color(1.0, 0.87, 0.2) if combo == 1 else Color(1.0, 0.5, 0.1),
		"size":  16 if combo == 1 else 20
	})
	if risk_bonus > 0:
		popups.append({
			"pos":   _g2p(pos) + Vector2(-28, 4),
			"text":  "RISKY +%d" % risk_bonus,
			"life":  0.85,
			"color": Color(1.0, 0.3, 0.3),
			"size":  13
		})

	# Every 50 pts spawn new void
	if score > 0 and score % 50 == 0:
		_schedule_void()

	# Grow max trail every 30 pts
	if score > 0 and score % 30 == 0:
		p_max_trail = mini(35, p_max_trail + 2)

	_spawn_star()

func _spawn_star() -> void:
	var pos := Vector2i.ZERO
	for _try in 60:
		pos = Vector2i(randi_range(1, COLS - 2), randi_range(1, ROWS - 2))
		if pos != p_pos and not p_trail.has(pos) and not star_list.has(pos):
			break
	star_list.append(pos)
	star_ages.append(randf() * TAU)

# ── Void spawning ──────────────────────────────────────────────────────────────
func _pick_spawn_pos() -> Vector2:
	var pp := _g2p(p_pos)
	var pos := Vector2.ZERO
	for _try in 60:
		if randf() < 0.5:
			pos.x = (1 if randf() < 0.5 else COLS - 2) * CELL + CELL * 0.5
			pos.y = randi_range(0, ROWS - 1) * CELL + CELL * 0.5
		else:
			pos.x = randi_range(0, COLS - 1) * CELL + CELL * 0.5
			pos.y = (1 if randf() < 0.5 else ROWS - 2) * CELL + CELL * 0.5
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
		# drifter extras
		"wander_target": pos,
		"wander_timer":  0.0,
	}

func _spawn_void(type: VoidType) -> void:
	void_list.append(_make_void(type, true))

func _schedule_void() -> void:
	# Pick type based on game time
	var type := VoidType.SEEKER
	var roll := randf()
	if game_time >= 60.0 and roll < 0.35:
		type = VoidType.AMBUSHER
	elif game_time >= 30.0 and roll < 0.50:
		type = VoidType.DRIFTER
	void_list.append(_make_void(type, false))   # starts in warning phase

# ── Difficulty milestones ──────────────────────────────────────────────────────
func _check_milestones() -> void:
	var thresholds := [30, 60, 120, 180]
	for t in thresholds:
		if game_time >= float(t) and not milestones_hit.has(t):
			milestones_hit.append(t)
			_trigger_milestone(t)

func _trigger_milestone(seconds: int) -> void:
	match seconds:
		30:
			announcements.append({"text": "WANDERERS APPROACH", "life": 3.0, "color": Color(0.5, 0.4, 1.0)})
			_schedule_void()
		60:
			announcements.append({"text": "HUNTERS DETECTED", "life": 3.0, "color": Color(1.0, 0.3, 0.3)})
			_schedule_void()
		120:
			announcements.append({"text": "THE VOID AWAKENS", "life": 3.5, "color": Color(1.0, 0.1, 0.5)})
			_schedule_void()
			_schedule_void()
		180:
			announcements.append({"text": "NO ESCAPE", "life": 3.5, "color": Color(1.0, 0.0, 0.0)})
			_schedule_void()

# ── Void update ────────────────────────────────────────────────────────────────
func _update_voids(delta: float) -> void:
	var pp := _g2p(p_pos)
	var time_scale := 1.0 + game_time / 150.0   # gentle ramp over 2.5 min

	for v in void_list:
		v["age"] += delta

		# ── Warning phase ──────────────────────────────────────────────────────
		if not v["active"]:
			v["warn_timer"] -= delta
			if v["warn_timer"] <= 0.0:
				v["active"] = true
			continue   # no movement while warning

		var birth_ramp : float = minf(1.0, v["age"] / 12.0)  # 0→1 over 12 seconds
		var type : VoidType = v["type"]

		# ── Per-personality movement ───────────────────────────────────────────
		match type:

			VoidType.SEEKER:
				# Direct pursuit, moderate speed
				var spd := (0.18 + void_list.size() * 0.018) * birth_ramp * time_scale
				var to_p : Vector2 = pp - v["pos"]
				if to_p.length() > 0.1:
					v["vel"] += to_p.normalized() * spd * 0.09

			VoidType.DRIFTER:
				# Slow wanderer that occasionally lurches toward player
				v["wander_timer"] -= delta
				if v["wander_timer"] <= 0.0:
					v["wander_timer"] = randf_range(1.5, 3.5)
					if randf() < 0.30:
						# pull toward player
						v["wander_target"] = pp + Vector2(randf_range(-60,60), randf_range(-60,60))
					else:
						# random wander
						v["wander_target"] = Vector2(
							randf_range(30.0, W - 30.0),
							randf_range(30.0, H - 30.0))

				var spd := (0.10 + void_list.size() * 0.010) * birth_ramp * time_scale
				var to_w : Vector2 = v["wander_target"] - v["pos"]
				if to_w.length() > 0.1:
					v["vel"] += to_w.normalized() * spd * 0.07
				# slight persistent pull toward player so it doesn't drift away forever
				var soft_pull : Vector2 = (pp - v["pos"]).normalized() * spd * 0.015
				v["vel"] += soft_pull

			VoidType.AMBUSHER:
				# Predicts where player will be in 5 steps and cuts it off
				var predicted : Vector2 = _g2p(p_pos + p_dir * 5)
				var to_pred   : Vector2 = predicted - v["pos"]
				var dist_pred : float   = to_pred.length()
				var spd := (0.24 + void_list.size() * 0.022) * birth_ramp * time_scale
				if dist_pred > 12.0:
					v["vel"] += to_pred.normalized() * spd * 0.11
				else:
					# Reached intercept point — lurk, waiting for player
					v["vel"] *= 0.88

		# ── Shared physics ─────────────────────────────────────────────────────
		v["vel"] *= 0.965     # drag
		v["pos"] += v["vel"]
		v["spin"] += v["spin_rate"]
		v["hunger"] = maxf(0.0, v["hunger"] - delta * 0.6)

		# Wall bounce
		var r : float = v["radius"]
		if v["pos"].x < r:     v["pos"].x = r;     v["vel"].x =  absf(v["vel"].x)
		if v["pos"].x > W - r: v["pos"].x = W - r; v["vel"].x = -absf(v["vel"].x)
		if v["pos"].y < r:     v["pos"].y = r;     v["vel"].y =  absf(v["vel"].y)
		if v["pos"].y > H - r: v["pos"].y = H - r; v["vel"].y = -absf(v["vel"].y)

		# Kill player on contact (grace period protects)
		if p_alive and p_grace <= 0.0:
			if (v["pos"] as Vector2).distance_to(pp) < r + 6.0:
				_kill_player(); return

		# Eat trail segments
		var eat_r : float = r + (6.0 if v["type"] == VoidType.DRIFTER else 4.0)
		var surviving : Array = []
		for seg: Vector2i in p_trail:
			var sp := _g2p(seg)
			if (v["pos"] as Vector2).distance_to(sp) < eat_r:
				v["hunger"] = minf(3.0, v["hunger"] + 1.0)
				score = maxi(0, score - 2)
			else:
				surviving.append(seg)
		p_trail = surviving

# ── Utility ────────────────────────────────────────────────────────────────────
func _g2p(g: Vector2i) -> Vector2:
	return Vector2(g.x * CELL + CELL * 0.5, g.y * CELL + CELL * 0.5)

# ══════════════════════════════════════════════════════════════════════════════
#  D R A W I N G
# ══════════════════════════════════════════════════════════════════════════════
func _draw() -> void:
	_draw_bg()
	match game_state:
		State.MENU:
			_draw_menu()
		State.PLAYING, State.DEAD:
			_draw_trail()
			_draw_stars()
			_draw_void_warnings()
			_draw_voids()
			_draw_player()
			_draw_popups()
			_draw_hud()
			_draw_announcements()
			if danger_glow > 0.01:
				_draw_danger_edge()
			if game_state == State.DEAD:
				_draw_death()

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

# ── Danger edge glow ────────────────────────────────────────────────────────────
func _draw_danger_edge() -> void:
	var a  := danger_glow * 0.45
	var pw := 22.0 * danger_glow
	var c  := Color(1.0, 0.1 + danger_glow * 0.1, 0.3, a)
	draw_rect(Rect2(0, 0, W, pw), c)
	draw_rect(Rect2(0, H - pw, W, pw), c)
	draw_rect(Rect2(0, 0, pw, H), c)
	draw_rect(Rect2(W - pw, 0, pw, H), c)

# ── Trail ──────────────────────────────────────────────────────────────────────
func _draw_trail() -> void:
	var n := p_trail.size()
	for i in n:
		var seg  : Vector2i = p_trail[i]
		var life : float    = 1.0 - float(i) / float(maxi(p_max_trail, 1))
		var col  : Color    = Color(life * 0.12, 0.57 + life * 0.43, 0.76 + life * 0.24,
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
	for i in star_list.size():
		var gpos := star_list[i] as Vector2i
		var age  := star_ages[i] as float
		var tw   := sin(age * 2.8) * 0.3 + 0.7
		var sp   := _g2p(gpos)
		var r    := 4.5 + tw * 3.0
		for ring in range(3, 0, -1):
			draw_circle(sp, r * (1.0 + ring * 0.5), Color(1.0, 0.87, 0.2, 0.035 * tw * ring))
		var pts := PackedVector2Array()
		for k in 10:
			var angle := -PI * 0.5 + k * TAU / 10.0
			var rad   := r if k % 2 == 0 else r * 0.42
			pts.append(sp + Vector2(cos(angle), sin(angle)) * rad)
		draw_colored_polygon(pts, Color(1.0, 0.93, 0.35, 0.88 + tw * 0.12))

# ── Void warning pulses ────────────────────────────────────────────────────────
func _draw_void_warnings() -> void:
	for v in void_list:
		if v["active"]: continue
		var progress : float = 1.0 - v["warn_timer"] / WARN_DURATION
		var pulse    : float = sin(game_time * 8.0) * 0.4 + 0.6
		var r        : float = (v["radius"] as float) * (1.5 + pulse * 0.5)
		var col      : Color
		match v["type"] as VoidType:
			VoidType.SEEKER:   col = Color(0.7, 0.0, 1.0, 0.35 * progress * pulse)
			VoidType.DRIFTER:  col = Color(0.3, 0.2, 1.0, 0.30 * progress * pulse)
			VoidType.AMBUSHER: col = Color(1.0, 0.2, 0.1, 0.40 * progress * pulse)
		draw_arc(v["pos"], r, 0.0, TAU, 32, col, 2.0)
		draw_arc(v["pos"], r * 0.6, 0.0, TAU, 24, Color(col.r, col.g, col.b, col.a * 0.5), 1.0)

# ── Voids ──────────────────────────────────────────────────────────────────────
func _draw_voids() -> void:
	for v in void_list:
		if not v["active"]: continue
		var pos    : Vector2  = v["pos"]
		var r      : float    = v["radius"]
		var spin   : float    = v["spin"]
		var hunger : float    = v["hunger"]
		var type   : VoidType = v["type"]
		var birth  : float    = minf(1.0, v["age"] / 2.0)   # fade in over 2s

		# Color theme per type
		var main_col : Color
		match type:
			VoidType.SEEKER:   main_col = Color(0.78, 0.18, 1.00)
			VoidType.DRIFTER:  main_col = Color(0.30, 0.22, 1.00)
			VoidType.AMBUSHER: main_col = Color(1.00, 0.28, 0.10)

		# Outer distortion rings
		for ring in range(4, 0, -1):
			var rr := r * (1.35 + ring * 0.6) + hunger * 4.0
			var a  := (0.05 + hunger * 0.06) / float(ring) * birth
			draw_arc(pos, rr, 0.0, TAU, 40, Color(main_col.r, main_col.g, main_col.b, a), 1.5)

		# Personality-specific details
		match type:
			VoidType.SEEKER:
				# Three spinning arms
				for arm in range(3):
					var angle := spin + arm * TAU / 3.0
					draw_arc(pos, r + r * 0.8, angle - 0.20, angle + 0.20, 10,
						Color(main_col.r, main_col.g, main_col.b, (0.65 + hunger * 0.25) * birth), 2.0 + hunger)
					var tip := pos + Vector2(cos(angle), sin(angle)) * (r * 2.0)
					draw_circle(tip, 2.5 + hunger, Color(0.9, 0.5, 1.0, 0.5 * birth))

			VoidType.DRIFTER:
				# Slow nebulous rings — no arms, just haze
				for ring in range(3):
					var rr2 := r * (0.8 + ring * 0.35 + sin(spin * 0.5 + ring) * 0.15)
					draw_arc(pos, rr2, spin + ring * 0.8, spin + ring * 0.8 + TAU * 0.6,
						20, Color(main_col.r, main_col.g, main_col.b, 0.18 * birth), 1.2)

			VoidType.AMBUSHER:
				# Crosshair / targeting reticle
				var tick_len := r * 0.6 + hunger * 2.0
				for arm in range(4):
					var angle := spin * 0.4 + arm * TAU / 4.0
					var inner := pos + Vector2(cos(angle), sin(angle)) * (r + 2.0)
					var outer := pos + Vector2(cos(angle), sin(angle)) * (r + tick_len)
					draw_line(inner, outer, Color(main_col.r, main_col.g, main_col.b,
						(0.8 + hunger * 0.2) * birth), 2.0)
				# Predicted intercept indicator
				var predicted := _g2p(p_pos + p_dir * 5)
				var to_pred   := (predicted - pos).normalized() * (r + 4.0)
				draw_line(pos + to_pred, pos + to_pred * 2.2,
					Color(1.0, 0.4, 0.1, 0.35 * birth), 1.0)

		# Dark core (all types)
		draw_circle(pos, r,        Color(0.00, 0.00, 0.00, 0.97 * birth))
		draw_circle(pos, r * 0.62, Color(0.07, 0.00, 0.13, 1.00 * birth))
		draw_circle(pos, r * 0.28, Color(main_col.r * 0.3, main_col.g * 0.1, main_col.b * 0.5, birth))

# ── Player ─────────────────────────────────────────────────────────────────────
func _draw_player() -> void:
	if not p_alive and fmod(death_timer * 9.0, 1.0) < 0.45: return

	var pp  := _g2p(p_pos)
	var eat := p_eat_flash

	# Grace period shield ring
	if p_grace > 0.0:
		var shield_a := (p_grace / GRACE_SEC) * (sin(game_time * 10.0) * 0.25 + 0.5)
		draw_arc(pp, 18.0 + glow_pulse * 3.0, 0.0, TAU, 40,
			Color(0.3, 1.0, 0.6, shield_a), 2.0)

	# Glow halos
	for ring in range(5, 0, -1):
		var rr := 7.0 + ring * 4.5 + glow_pulse * 4.0 + eat * 8.0
		var a  := 0.05 * float(6 - ring) / 5.0 + eat * 0.06
		draw_circle(pp, rr, Color(0.0, 1.0, 1.0, a))

	# Direction arrow
	var tip  := pp + Vector2(p_dir.x, p_dir.y) * 10.5
	var perp := Vector2(-p_dir.y, p_dir.x) * 3.5
	draw_colored_polygon(
		PackedVector2Array([tip, pp + perp * 0.6, pp - perp * 0.6]),
		Color(0.5, 1.0, 1.0, 0.55))

	draw_circle(pp, 5.2 + glow_pulse * 1.5 + eat * 2.0, Color(1.0, 1.0, 1.0, 0.96))
	draw_circle(pp, 2.4, Color(0.6, 1.0, 1.0, 1.0))

# ── Popups ──────────────────────────────────────────────────────────────────────
func _draw_popups() -> void:
	for pop in popups:
		var life  : float = pop["life"]
		var rise  : float = (1.0 - life) * 30.0
		var alpha : float = life if life > 0.5 else life * 2.0
		var col   : Color = pop["color"]
		col.a = alpha
		draw_string(font, pop["pos"] - Vector2(0, rise), pop["text"],
			HORIZONTAL_ALIGNMENT_LEFT, -1, pop["size"], col)

# ── Announcements (centered) ────────────────────────────────────────────────────
func _draw_announcements() -> void:
	for ann in announcements:
		var life  : float = ann["life"]
		var alpha : float = minf(1.0, life * 2.0) * minf(1.0, (ann["life"]) * 1.5)
		var col   : Color = ann["color"]
		col.a = alpha
		# glow layers
		for layer in range(3, 0, -1):
			draw_string(font, Vector2(0, H * 0.5 - 110),
				ann["text"], HORIZONTAL_ALIGNMENT_CENTER, W, 26 + layer,
				Color(col.r, col.g, col.b, 0.07 * float(4-layer) * alpha))
		draw_string(font, Vector2(0, H * 0.5 - 110),
			ann["text"], HORIZONTAL_ALIGNMENT_CENTER, W, 26, col)

# ── HUD ─────────────────────────────────────────────────────────────────────────
func _draw_hud() -> void:
	draw_string(font, Vector2(14, 22), "SCORE  %d" % score,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0, 1, 1, 0.85))
	draw_string(font, Vector2(14, 42), "BEST   %d" % best_score,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0, 1, 1, 0.5))
	draw_string(font, Vector2(14, 62), "VOIDS  %d" % void_list.filter(func(v): return v["active"]).size(),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.7, 0.2, 1.0, 0.8))

	# Survival time
	var mins := int(game_time) / 60
	var secs := int(game_time) % 60
	draw_string(font, Vector2(W - 90, 22), "%02d:%02d" % [mins, secs],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0, 1, 1, 0.45))

	# Combo meter
	if combo > 1 and combo_timer > 0.0:
		var bar_w := 80.0 * (combo_timer / COMBO_WINDOW)
		draw_rect(Rect2(W - 94, 36, 82, 8), Color(0.15, 0.08, 0.0, 0.6))
		draw_rect(Rect2(W - 94, 36, bar_w, 8), Color(1.0, 0.55, 0.1, 0.85))
		draw_string(font, Vector2(W - 94, 58), "COMBO  x%d" % combo,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1.0, 0.6, 0.1, 0.92))

	# Void type legend  (small, bottom right)
	var legend_y := H - 46.0
	for entry in [["SEEKER", Color(0.78, 0.18, 1.00)],
				  ["DRIFTER", Color(0.30, 0.22, 1.00)],
				  ["AMBUSHER", Color(1.00, 0.28, 0.10)]]:
		var label : String = entry[0]
		var col   : Color  = entry[1]
		var count := void_list.filter(func(v): return v["active"] and v["type"] == VoidType[label]).size()
		if count > 0:
			draw_string(font, Vector2(W - 90, legend_y), "%s %d" % [label, count],
				HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(col.r, col.g, col.b, 0.55))
			legend_y -= 14.0

	draw_string(font, Vector2(12, H - 8), "trail %d / %d" % [p_trail.size(), p_max_trail],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0, 1, 1, 0.28))

# ── Menu ─────────────────────────────────────────────────────────────────────────
func _draw_menu() -> void:
	var pulse := 0.82 + 0.18 * sin(game_time * 2.8)
	var cy    := H * 0.5

	for layer in range(3, 0, -1):
		draw_string(font, Vector2(0, cy - 72), "VOID WALKER",
			HORIZONTAL_ALIGNMENT_CENTER, W, 60 + layer * 2,
			Color(0.0, 1.0, 1.0, 0.07 * float(4 - layer) * pulse))
	draw_string(font, Vector2(0, cy - 72), "VOID WALKER",
		HORIZONTAL_ALIGNMENT_CENTER, W, 60, Color(0.0, 1.0, 1.0, pulse))

	draw_string(font, Vector2(0, cy - 16), "YOUR LIGHT TRAIL IS YOUR WEAPON",
		HORIZONTAL_ALIGNMENT_CENTER, W, 16, Color(0.0, 1.0, 1.0, 0.57))
	draw_string(font, Vector2(0, cy + 8), "AND YOUR PRISON",
		HORIZONTAL_ALIGNMENT_CENTER, W, 16, Color(0.0, 1.0, 1.0, 0.44))

	draw_line(Vector2(W * 0.25, cy + 28), Vector2(W * 0.75, cy + 28),
		Color(0.0, 1.0, 1.0, 0.18), 1.0)

	var tips := [
		["collect  ★  stars  —  erase trail & score",   Color(1.0, 0.93, 0.35, 0.42)],
		["chain stars fast  —  build a COMBO multiplier", Color(1.0, 0.6, 0.1, 0.42)],
		["avoid   ⊕  voids  —  3 types hunt differently", Color(0.78, 0.4, 1.0, 0.42)],
		["risky collect near a void  =  bonus points",    Color(1.0, 0.4, 0.4, 0.42)],
	]
	var ty := cy + 52.0
	for tip in tips:
		draw_string(font, Vector2(0, ty), tip[0],
			HORIZONTAL_ALIGNMENT_CENTER, W, 13, tip[1])
		ty += 20.0

	if fmod(game_time, 1.1) < 0.65:
		draw_string(font, Vector2(0, cy + 156), "─  PRESS ANY ARROW KEY  ─",
			HORIZONTAL_ALIGNMENT_CENTER, W, 19, Color(1, 1, 1, 0.88))
	if best_score > 0:
		draw_string(font, Vector2(0, cy + 186), "BEST  %d" % best_score,
			HORIZONTAL_ALIGNMENT_CENTER, W, 13, Color(1.0, 0.87, 0.2, 0.65))

# ── Death ───────────────────────────────────────────────────────────────────────
func _draw_death() -> void:
	draw_rect(Rect2(0, 0, W, H), Color(0, 0, 0, minf(0.82, death_timer * 1.2)))
	if death_timer < 0.35: return
	var fade := minf(1.0, (death_timer - 0.35) / 0.6)
	var cy   := H * 0.5

	for layer in range(3, 0, -1):
		draw_string(font, Vector2(0, cy - 52), "CONSUMED",
			HORIZONTAL_ALIGNMENT_CENTER, W, 58 + layer * 2,
			Color(1.0, 0.02, 0.27, 0.06 * float(4-layer) * fade))
	draw_string(font, Vector2(0, cy - 52), "CONSUMED",
		HORIZONTAL_ALIGNMENT_CENTER, W, 58, Color(1.0, 0.05, 0.30, fade))

	draw_string(font, Vector2(0, cy + 12), "SCORE  %d" % score,
		HORIZONTAL_ALIGNMENT_CENTER, W, 24, Color(1, 1, 1, 0.88 * fade))

	# Survival time
	var mins := int(game_time) / 60
	var secs := int(game_time) % 60
	draw_string(font, Vector2(0, cy + 40), "SURVIVED  %02d:%02d" % [mins, secs],
		HORIZONTAL_ALIGNMENT_CENTER, W, 15, Color(0, 1, 1, 0.6 * fade))

	if score >= best_score and score > 0:
		draw_string(font, Vector2(0, cy + 64), "✦  NEW BEST  ✦",
			HORIZONTAL_ALIGNMENT_CENTER, W, 16, Color(1.0, 0.87, 0.2, fade))

	if death_timer > 1.5 and fmod(game_time, 1.05) < 0.60:
		draw_string(font, Vector2(0, cy + 92), "─  PRESS ANY KEY TO RETRY  ─",
			HORIZONTAL_ALIGNMENT_CENTER, W, 16, Color(1, 1, 1, 0.72 * fade))
