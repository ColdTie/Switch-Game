## ═══════════════════════════════════════════════════════════
##  V O I D   W A L K E R  —  Main.gd
##  Single-script game. All logic + custom rendering lives here.
##  Your trail: weapon AND prison.
## ═══════════════════════════════════════════════════════════
extends Node2D

# ── Constants ────────────────────────────────────────────────
const CELL       := 20
const COLS       := 40
const ROWS       := 30
const W          := COLS * CELL   # 800
const H          := ROWS * CELL   # 600
const MOVE_SEC   := 0.13          # seconds between grid ticks

# ── Game state enum ──────────────────────────────────────────
enum State { MENU, PLAYING, DEAD }

# ── Runtime state ────────────────────────────────────────────
var game_state   : State  = State.MENU
var score        : int    = 0
var best_score   : int    = 0

# ── Player ───────────────────────────────────────────────────
var p_pos        : Vector2i = Vector2i(COLS / 2, ROWS / 2)
var p_dir        : Vector2i = Vector2i(1, 0)
var p_next_dir   : Vector2i = Vector2i(1, 0)
var p_trail      : Array    = []   # Array[Vector2i]
var p_max_trail  : int      = 12
var p_alive      : bool     = true
var p_eat_flash  : float    = 0.0

# ── Voids ────────────────────────────────────────────────────
# Each void is a Dictionary: {pos, vel, spin, spin_rate, radius, hunger}
var void_list    : Array    = []

# ── Stars ────────────────────────────────────────────────────
var star_list    : Array    = []   # Array[Vector2i]
var star_ages    : Array    = []   # parallel float array for twinkle phase

# ── Score popups ─────────────────────────────────────────────
var popups       : Array    = []   # [{pos, text, life, color}]

# ── Timers & animation ───────────────────────────────────────
var move_accum   : float    = 0.0
var game_time    : float    = 0.0
var glow_pulse   : float    = 0.0
var death_timer  : float    = 0.0
var bg_offset    : float    = 0.0

# ── Cached font ──────────────────────────────────────────────
var font         : Font

# ── Background drift particles ───────────────────────────────
var bg_particles : Array    = []

# ─────────────────────────────────────────────────────────────
func _ready() -> void:
	font = ThemeDB.fallback_font
	_load_best()

	# Build background drift particles
	for i in 180:
		bg_particles.append({
			"x": randf() * W,
			"y": randf() * H,
			"r": randf() * 1.2 + 0.3,
			"b": randf(),
			"drift": (randf() - 0.5) * 0.12
		})

# ── Persistence ─────────────────────────────────────────────
func _load_best() -> void:
	var f := FileAccess.open("user://best.txt", FileAccess.READ)
	if f:
		best_score = int(f.get_as_text().strip_edges())
		f.close()

func _save_best() -> void:
	var f := FileAccess.open("user://best.txt", FileAccess.WRITE)
	if f:
		f.store_string(str(best_score))
		f.close()

# ── Update loop ──────────────────────────────────────────────
func _process(delta: float) -> void:
	game_time  += delta
	glow_pulse  = sin(game_time * 6.0) * 0.5 + 0.5
	bg_offset   = fmod(bg_offset + delta * 8.0, W)

	# Drift background particles
	for p in bg_particles:
		p["x"] = fmod(p["x"] + p["drift"] + W, W)

	match game_state:
		State.PLAYING:
			move_accum += delta
			if move_accum >= MOVE_SEC:
				move_accum -= MOVE_SEC
				_step()
			_update_voids(delta)
			p_eat_flash = max(0.0, p_eat_flash - delta * 4.0)
			# Tick star ages
			for i in star_ages.size():
				star_ages[i] += delta

		State.DEAD:
			death_timer += delta
			_update_voids(delta)   # keep voids moving on death screen

	# Update popups
	var alive_popups : Array = []
	for pop in popups:
		pop["life"] -= delta
		if pop["life"] > 0.0:
			alive_popups.append(pop)
	popups = alive_popups

	queue_redraw()

# ── Input ────────────────────────────────────────────────────
func _input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed):
		return
	var kev := event as InputEventKey

	if game_state == State.MENU or game_state == State.DEAD:
		var start_keys := [KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT,
							KEY_W, KEY_A, KEY_S, KEY_D, KEY_SPACE, KEY_ENTER]
		if kev.keycode in start_keys:
			if game_state == State.DEAD and death_timer < 1.5:
				return
			_start_game()
			return

	if game_state == State.PLAYING:
		match kev.keycode:
			KEY_UP,    KEY_W:
				if p_dir.y != 1:  p_next_dir = Vector2i(0, -1)
			KEY_DOWN,  KEY_S:
				if p_dir.y != -1: p_next_dir = Vector2i(0, 1)
			KEY_LEFT,  KEY_A:
				if p_dir.x != 1:  p_next_dir = Vector2i(-1, 0)
			KEY_RIGHT, KEY_D:
				if p_dir.x != -1: p_next_dir = Vector2i(1, 0)

# ── Game lifecycle ───────────────────────────────────────────
func _start_game() -> void:
	score        = 0
	p_pos        = Vector2i(COLS / 2, ROWS / 2)
	p_dir        = Vector2i(1, 0)
	p_next_dir   = Vector2i(1, 0)
	p_trail      = []
	p_max_trail  = 12
	p_alive      = true
	p_eat_flash  = 0.0
	void_list    = []
	star_list    = []
	star_ages    = []
	popups       = []
	move_accum   = 0.0
	death_timer  = 0.0
	game_time    = 0.0

	_spawn_void()
	for _i in 3:
		_spawn_star()

	game_state = State.PLAYING

func _kill_player() -> void:
	if not p_alive: return
	p_alive = false
	game_state = State.DEAD
	death_timer = 0.0
	if score > best_score:
		best_score = score
		_save_best()

# ── Grid step ────────────────────────────────────────────────
func _step() -> void:
	p_dir = p_next_dir
	var nx := p_pos.x + p_dir.x
	var ny := p_pos.y + p_dir.y

	# Wall hit
	if nx < 0 or nx >= COLS or ny < 0 or ny >= ROWS:
		_kill_player(); return

	var np := Vector2i(nx, ny)

	# Self collision
	for seg: Vector2i in p_trail:
		if seg == np:
			_kill_player(); return

	# Star collection
	var star_idx := -1
	for i in star_list.size():
		if star_list[i] == np:
			star_idx = i; break

	if star_idx >= 0:
		_eat_star(star_idx, np)

	# Advance trail
	p_trail.push_front(p_pos)
	if p_trail.size() > p_max_trail:
		p_trail.pop_back()

	p_pos = np

# ── Star ─────────────────────────────────────────────────────
func _eat_star(idx: int, pos: Vector2i) -> void:
	star_list.remove_at(idx)
	star_ages.remove_at(idx)
	score += 10
	p_eat_flash = 1.0

	# Erase 4 oldest trail segments
	var erase := mini(4, p_trail.size())
	for _i in erase:
		p_trail.pop_back()

	popups.append({
		"pos":   _g2p(pos) + Vector2(-20, -12),
		"text":  "+10",
		"life":  0.9,
		"color": Color(1.0, 0.87, 0.2)
	})

	# New void every 50 pts
	if score > 0 and score % 50 == 0:
		_spawn_void()

	# Grow max trail every 30 pts
	if score > 0 and score % 30 == 0:
		p_max_trail = mini(35, p_max_trail + 2)

	_spawn_star()

# ── Spawners ─────────────────────────────────────────────────
func _spawn_void() -> void:
	var pos := Vector2.ZERO
	var pp  := _g2p(p_pos)
	var tries := 0

	while tries < 60:
		tries += 1
		if randf() < 0.5:
			pos.x = (1 if randf() < 0.5 else COLS - 2) * CELL + CELL * 0.5
			pos.y = randi_range(0, ROWS - 1) * CELL + CELL * 0.5
		else:
			pos.x = randi_range(0, COLS - 1) * CELL + CELL * 0.5
			pos.y = (1 if randf() < 0.5 else ROWS - 2) * CELL + CELL * 0.5
		if pos.distance_to(pp) > 160.0:
			break

	void_list.append({
		"pos":       pos,
		"vel":       Vector2((randf() - 0.5) * 0.8, (randf() - 0.5) * 0.8),
		"spin":      randf() * TAU,
		"spin_rate": (randf() - 0.5) * 0.05,
		"radius":    18.0,
		"hunger":    0.0
	})

func _spawn_star() -> void:
	var pos  := Vector2i.ZERO
	var tries := 0
	while tries < 60:
		tries += 1
		pos = Vector2i(randi_range(1, COLS - 2), randi_range(1, ROWS - 2))
		if pos != p_pos and not p_trail.has(pos) and not star_list.has(pos):
			break
	star_list.append(pos)
	star_ages.append(randf() * TAU)  # random phase offset

# ── Void update ──────────────────────────────────────────────
func _update_voids(delta: float) -> void:
	var pp := _g2p(p_pos)

	for v in void_list:
		var to_p : Vector2 = pp - v["pos"]
		var dist : float   = to_p.length()
		var speed: float   = 0.38 + void_list.size() * 0.055

		if dist > 0.1:
			v["vel"] += to_p.normalized() * speed * 0.09
		v["vel"]  *= 0.97
		v["pos"]  += v["vel"]
		v["spin"] += v["spin_rate"]
		v["hunger"] = maxf(0.0, v["hunger"] - delta * 0.6)

		# Boundary bounce
		var r: float = v["radius"]
		if v["pos"].x < r:
			v["pos"].x = r;         v["vel"].x =  absf(v["vel"].x)
		if v["pos"].x > W - r:
			v["pos"].x = W - r;     v["vel"].x = -absf(v["vel"].x)
		if v["pos"].y < r:
			v["pos"].y = r;         v["vel"].y =  absf(v["vel"].y)
		if v["pos"].y > H - r:
			v["pos"].y = H - r;     v["vel"].y = -absf(v["vel"].y)

		# Player collision
		if p_alive and v["pos"].distance_to(pp) < r + 6.0:
			_kill_player(); return

		# Eat trail segments
		var surviving : Array = []
		for seg: Vector2i in p_trail:
			var sp := _g2p(seg)
			if v["pos"].distance_to(sp) < r + 4.0:
				v["hunger"] = minf(3.0, v["hunger"] + 1.0)
				score        = maxi(0, score - 2)
			else:
				surviving.append(seg)
		p_trail = surviving

# ── Pixel conversion ─────────────────────────────────────────
func _g2p(g: Vector2i) -> Vector2:
	return Vector2(g.x * CELL + CELL * 0.5, g.y * CELL + CELL * 0.5)

# ═════════════════════════════════════════════════════════════
#  D R A W I N G
# ═════════════════════════════════════════════════════════════
func _draw() -> void:
	_draw_bg()

	match game_state:
		State.MENU:
			_draw_menu()
		State.PLAYING:
			_draw_trail()
			_draw_stars()
			_draw_voids()
			_draw_player()
			_draw_popups()
			_draw_hud()
		State.DEAD:
			_draw_trail()
			_draw_stars()
			_draw_voids()
			_draw_player()
			_draw_popups()
			_draw_hud()
			_draw_death()

# ── Background ───────────────────────────────────────────────
func _draw_bg() -> void:
	draw_rect(Rect2(0, 0, W, H), Color(0.020, 0.020, 0.030))

	# Grid lines
	var gc := Color(0.0, 0.23, 0.31, 0.18)
	for x in range(0, W + 1, CELL):
		draw_line(Vector2(x, 0), Vector2(x, H), gc, 0.5)
	for y in range(0, H + 1, CELL):
		draw_line(Vector2(0, y), Vector2(W, y), gc, 0.5)

	# Drifting background particles
	for p in bg_particles:
		var bright: float = 0.2 + p["b"] * 0.4 * (0.7 + 0.3 * sin(game_time * 0.8 + p["b"] * 10.0))
		draw_circle(Vector2(p["x"], p["y"]), p["r"], Color(0.39, 0.78, 1.0, bright * 0.55))

# ── Trail ─────────────────────────────────────────────────────
func _draw_trail() -> void:
	var n := p_trail.size()
	for i in n:
		var seg  : Vector2i = p_trail[i]
		var life : float    = 1.0 - float(i) / float(maxi(p_max_trail, 1))
		var alpha: float    = 0.14 + life * 0.72
		var col  : Color    = Color(life * 0.12, 0.58 + life * 0.42, 0.77 + life * 0.23, alpha)
		var ctr  : Vector2  = _g2p(seg)
		var s    : float    = CELL - 4.0
		draw_rect(Rect2(ctr.x - s * 0.5, ctr.y - s * 0.5, s, s), col)
		# Inner highlight for recent segments
		if life > 0.7:
			var hl_a := (life - 0.7) / 0.3 * 0.35
			draw_rect(Rect2(ctr.x - s * 0.5 + 2, ctr.y - s * 0.5 + 2, s - 4, s - 4),
				Color(0.6, 1.0, 1.0, hl_a))

# ── Stars ─────────────────────────────────────────────────────
func _draw_stars() -> void:
	for i in star_list.size():
		var gpos := star_list[i] as Vector2i
		var age  := star_ages[i] as float
		var tw   := sin(age * 2.8) * 0.3 + 0.7
		var sp   := _g2p(gpos)
		var r    := 4.5 + tw * 3.0

		# Outer glow
		for ring in range(3, 0, -1):
			draw_circle(sp, r * (1.0 + ring * 0.5), Color(1.0, 0.87, 0.2, 0.04 * tw * ring))

		# 5-point star polygon
		var pts := PackedVector2Array()
		for k in 10:
			var angle := -PI * 0.5 + k * TAU / 10.0
			var rad   := r if k % 2 == 0 else r * 0.42
			pts.append(sp + Vector2(cos(angle), sin(angle)) * rad)
		draw_colored_polygon(pts, Color(1.0, 0.93, 0.35, 0.85 + tw * 0.15))

# ── Player ────────────────────────────────────────────────────
func _draw_player() -> void:
	# Flicker on death
	if not p_alive and fmod(death_timer * 9.0, 1.0) < 0.45:
		return

	var pp  := _g2p(p_pos)
	var eat := p_eat_flash

	# Concentric glow halos
	for ring in range(5, 0, -1):
		var r := 7.0 + ring * 4.5 + glow_pulse * 4.0 + eat * 8.0
		var a := 0.055 * float(6 - ring) / 5.0 + eat * 0.06
		draw_circle(pp, r, Color(0.0, 1.0, 1.0, a))

	# Direction indicator (small triangle showing heading)
	var tip := pp + Vector2(p_dir.x, p_dir.y) * 10.0
	var perp := Vector2(-p_dir.y, p_dir.x) * 4.0
	var arrow := PackedVector2Array([tip, pp + perp * 0.6, pp - perp * 0.6])
	draw_colored_polygon(arrow, Color(0.5, 1.0, 1.0, 0.5))

	# Core dot
	draw_circle(pp, 5.0 + glow_pulse * 1.5 + eat * 2.0, Color(1.0, 1.0, 1.0, 0.95))
	draw_circle(pp, 2.5, Color(0.6, 1.0, 1.0, 1.0))

# ── Voids ─────────────────────────────────────────────────────
func _draw_voids() -> void:
	for v in void_list:
		var pos    : Vector2 = v["pos"]
		var r      : float   = v["radius"]
		var spin   : float   = v["spin"]
		var hunger : float   = v["hunger"]

		# Outer distortion rings
		for ring in range(4, 0, -1):
			var rr := r * (1.4 + ring * 0.65) + hunger * 4.0
			var a  := (0.055 + hunger * 0.07) / float(ring)
			draw_arc(pos, rr, 0.0, TAU, 40, Color(0.7, 0.0, 1.0, a), 1.5)

		# Three spinning arm arcs
		for arm in range(3):
			var base_angle := spin + arm * TAU / 3.0
			var arm_len    := r * 1.6 + hunger * 3.0
			var arm_w      := 1.8 + hunger * 0.7
			var a_col      := Color(0.78, 0.18, 1.0, 0.65 + hunger * 0.25)
			# Approximate curved arm with a short arc
			draw_arc(pos, r + arm_len * 0.5,
				base_angle - 0.22, base_angle + 0.22, 12, a_col, arm_w)
			# Tip flare
			var tip := pos + Vector2(cos(base_angle), sin(base_angle)) * (r + arm_len)
			draw_circle(tip, 2.0 + hunger, Color(0.9, 0.5, 1.0, 0.5 + hunger * 0.3))

		# Dark core (layered circles to fake a radial gradient)
		draw_circle(pos, r,         Color(0.0,  0.0,  0.0,  0.97))
		draw_circle(pos, r * 0.65,  Color(0.07, 0.0,  0.14, 1.0))
		draw_circle(pos, r * 0.30,  Color(0.14, 0.0,  0.28, 1.0))

# ── Score popups ──────────────────────────────────────────────
func _draw_popups() -> void:
	for pop in popups:
		var life  : float   = pop["life"]
		var rise  : float   = (1.0 - life) * 28.0
		var alpha : float   = life * (1.0 if life > 0.5 else life * 2.0)
		var col   : Color   = pop["color"]
		col.a = alpha
		draw_string(font, pop["pos"] - Vector2(0, rise), pop["text"],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 17, col)

# ── HUD ───────────────────────────────────────────────────────
func _draw_hud() -> void:
	var cy := Color(0.0, 1.0, 1.0, 0.85)
	var cm := Color(0.7, 0.2, 1.0, 0.80)
	var cd := Color(0.0, 1.0, 1.0, 0.30)
	draw_string(font, Vector2(14, 22), "SCORE  %d" % score, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, cy)
	draw_string(font, Vector2(14, 42), "BEST   %d" % best_score, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0,1,1,0.5))
	draw_string(font, Vector2(14, 62), "VOIDS  %d" % void_list.size(), HORIZONTAL_ALIGNMENT_LEFT, -1, 13, cm)
	draw_string(font, Vector2(12, H - 8), "trail %d / %d" % [p_trail.size(), p_max_trail],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, cd)

# ── Menu ──────────────────────────────────────────────────────
func _draw_menu() -> void:
	var pulse := 0.82 + 0.18 * sin(game_time * 2.8)
	var cy    := H * 0.5

	# Title with glow layers
	for layer in range(3, 0, -1):
		var a := 0.08 * float(4 - layer) * pulse
		draw_string(font, Vector2(0, cy - 72), "VOID WALKER",
			HORIZONTAL_ALIGNMENT_CENTER, W, 58 + layer * 2, Color(0.0, 1.0, 1.0, a))
	draw_string(font, Vector2(0, cy - 72), "VOID WALKER",
		HORIZONTAL_ALIGNMENT_CENTER, W, 58, Color(0.0, 1.0, 1.0, pulse))

	draw_string(font, Vector2(0, cy - 16), "YOUR LIGHT TRAIL IS YOUR WEAPON",
		HORIZONTAL_ALIGNMENT_CENTER, W, 16, Color(0.0, 1.0, 1.0, 0.58))
	draw_string(font, Vector2(0, cy + 8), "AND YOUR PRISON",
		HORIZONTAL_ALIGNMENT_CENTER, W, 16, Color(0.0, 1.0, 1.0, 0.45))

	# Separator line
	draw_line(Vector2(W * 0.25, cy + 28), Vector2(W * 0.75, cy + 28),
		Color(0.0, 1.0, 1.0, 0.2), 1.0)

	draw_string(font, Vector2(0, cy + 52), "collect  ★  stars  —  erase your trail",
		HORIZONTAL_ALIGNMENT_CENTER, W, 13, Color(1, 1, 1, 0.42))
	draw_string(font, Vector2(0, cy + 72), "avoid   ⊕  voids  —  they devour it",
		HORIZONTAL_ALIGNMENT_CENTER, W, 13, Color(1, 1, 1, 0.42))
	draw_string(font, Vector2(0, cy + 92), "do not cross your own trail",
		HORIZONTAL_ALIGNMENT_CENTER, W, 13, Color(1, 1, 1, 0.42))

	# Blinking prompt
	if fmod(game_time, 1.1) < 0.65:
		draw_string(font, Vector2(0, cy + 138), "─  PRESS ANY ARROW KEY  ─",
			HORIZONTAL_ALIGNMENT_CENTER, W, 19, Color(1, 1, 1, 0.88))

	if best_score > 0:
		draw_string(font, Vector2(0, cy + 172), "BEST  %d" % best_score,
			HORIZONTAL_ALIGNMENT_CENTER, W, 13, Color(1.0, 0.87, 0.2, 0.65))

# ── Death overlay ─────────────────────────────────────────────
func _draw_death() -> void:
	var overlay_a := minf(0.82, death_timer * 1.2)
	draw_rect(Rect2(0, 0, W, H), Color(0, 0, 0, overlay_a))

	if death_timer < 0.35:
		return

	var fade := minf(1.0, (death_timer - 0.35) / 0.6)
	var cy   := H * 0.5

	# "CONSUMED" with red glow
	for layer in range(3, 0, -1):
		draw_string(font, Vector2(0, cy - 52), "CONSUMED",
			HORIZONTAL_ALIGNMENT_CENTER, W, 56 + layer * 2,
			Color(1.0, 0.02, 0.27, 0.06 * float(4 - layer) * fade))
	draw_string(font, Vector2(0, cy - 52), "CONSUMED",
		HORIZONTAL_ALIGNMENT_CENTER, W, 56, Color(1.0, 0.05, 0.30, fade))

	draw_string(font, Vector2(0, cy + 12), "SCORE  %d" % score,
		HORIZONTAL_ALIGNMENT_CENTER, W, 24, Color(1, 1, 1, 0.88 * fade))

	if score >= best_score and score > 0:
		draw_string(font, Vector2(0, cy + 44), "✦  NEW BEST  ✦",
			HORIZONTAL_ALIGNMENT_CENTER, W, 16, Color(1.0, 0.87, 0.2, fade))

	if death_timer > 1.5 and fmod(game_time, 1.05) < 0.60:
		draw_string(font, Vector2(0, cy + 82), "─  PRESS ANY KEY TO RETRY  ─",
			HORIZONTAL_ALIGNMENT_CENTER, W, 16, Color(1, 1, 1, 0.72 * fade))
