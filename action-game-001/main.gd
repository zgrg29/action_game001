extends Node2D

const VIEW_SIZE := Vector2(960, 540)
const FIELD := Rect2(266, 18, 428, 504)
const PLAYER_SPEED := 300.0
const BULLET_RADIUS := 5.0
const SAVE_PATH := "user://ember_save.json"
const WEAPONS := [
	{"name": "脉冲散射炮", "desc": "扇形散射，近距离威力高", "key": "scatter"},
	{"name": "穿甲轨道炮", "desc": "蓄力射击，可贯穿敌机", "key": "rail"},
	{"name": "追踪蜂群", "desc": "自动追踪最近敌机", "key": "seeker"},
	{"name": "弧链电弧", "desc": "命中后跳跃攻击附近目标", "key": "arc"},
	{"name": "火箭齐射", "desc": "爆炸伤害，适合清理敌群", "key": "rocket"},
	{"name": "防御无人机", "desc": "无人机自动补充火力", "key": "drone"}
]
const STAGE_UPGRADES := [
	{"name": "生命扩充", "desc": "最大生命 +1，并恢复 1 格", "key": "health"},
	{"name": "火力强化", "desc": "所有武器伤害 +2", "key": "damage"},
	{"name": "能量回满", "desc": "立即填满擦弹能量", "key": "energy"}
]

var rng := RandomNumberGenerator.new()
var player := Vector2(480, 445)
var player_hp := 3
var player_max_hp := 3
var invuln := 0.0
var dash_energy := 0.0
var dash_damage := 5
var dash_cooldown := 0.0
var player_damage := 3
var graze_bonus := 1.0
var seek_timer := 0.0
var fire_timer := 0.0
var enemies: Array = []
var enemy_bullets: Array = []
var player_bullets: Array = []
var particles: Array = []
var stars: Array = []
var score := 0
var wave := 0
var wave_timer := 0.0
var spawn_timer := 1.0
var wave_kills := 0
var boss := {}
var boss_active := false
var boss_bullet_timer := 0.0
var phase := "title"
var paused := false
var upgrade_options: Array = []
var message := ""
var message_timer := 0.0
var ember := 0
var total_runs := 0
var permanent_armor := 0
var run_reward := 0
var reward_claimed := false
var checkpoint: Dictionary = {}
var hangar_notice := ""
var weapon_levels := {"pulse": 1}
var store_selection := 0

func _ready() -> void:
	_load_save()
	rng.randomize()
	for i in range(100):
		stars.append({"p": Vector2(rng.randf_range(FIELD.position.x, FIELD.end.x), rng.randf_range(0, VIEW_SIZE.y)), "s": rng.randf_range(0.7, 2.4), "v": rng.randf_range(18, 75)})
	set_process(true)
	queue_redraw()

func _unhandled_input(event: InputEvent) -> void:
	if phase == "store":
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			_handle_store_click(event.position)
			return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			if phase == "playing":
				paused = not paused
				queue_redraw()
			elif paused:
				paused = false
				queue_redraw()
			elif phase == "victory":
				return_to_title_after_victory()
			elif phase == "gameover":
				start_game()
			elif phase == "store":
				phase = "title"
			elif phase == "title":
				phase = "store"
		elif event.keycode in [KEY_SPACE, KEY_ENTER] and phase == "title":
			start_game()
		elif event.keycode in [KEY_ENTER, KEY_SPACE] and phase == "victory":
			return_to_title_after_victory()
		elif phase == "gameover" and event.keycode in [KEY_1, KEY_2]:
			if event.keycode == KEY_1: return_to_hangar()
			else: retry_checkpoint()
		elif phase == "title" and event.keycode == KEY_B:
			phase = "store"
		elif phase == "store":
			if event.keycode == KEY_B:
				phase = "title"
			elif event.keycode == KEY_Q:
				buy_hangar_upgrade()
			elif event.keycode in [KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6]:
				store_selection = event.keycode - KEY_1
			elif event.keycode in [KEY_LEFT, KEY_MINUS, KEY_KP_SUBTRACT]:
				adjust_weapon(-1)
			elif event.keycode in [KEY_RIGHT, KEY_EQUAL, KEY_KP_ADD]:
				adjust_weapon(1)
		elif phase == "upgrade" and event.keycode in [KEY_1, KEY_2, KEY_3]:
			choose_upgrade(event.keycode - KEY_1)
		elif phase == "route" and event.keycode in [KEY_1, KEY_2]:
			choose_route(event.keycode - KEY_1)
		elif phase == "playing" and event.keycode in [KEY_K, KEY_X]:
			try_dash()

func start_game() -> void:
	total_runs += 1
	run_reward = 0
	reward_claimed = false
	player = Vector2(480, 445)
	player_max_hp = 3 + permanent_armor
	player_hp = player_max_hp
	invuln = 1.5
	dash_energy = 0.0
	dash_damage = 5
	dash_cooldown = 0.0
	player_damage = 3
	graze_bonus = 1.0
	seek_timer = 0.0
	fire_timer = 0.0
	enemies.clear()
	enemy_bullets.clear()
	player_bullets.clear()
	particles.clear()
	score = 0
	wave = 0
	wave_timer = 0.0
	spawn_timer = 0.8
	wave_kills = 0
	boss.clear()
	boss_active = false
	phase = "playing"
	paused = false
	message = "航段 01 · 残骸带"
	message_timer = 2.2
	_save_checkpoint()

func _process(delta: float) -> void:
	var dt := minf(delta, 0.04)
	for star in stars:
		star.p.y += star.v * dt
		if star.p.y > VIEW_SIZE.y:
			star.p.y = -3
			star.p.x = rng.randf_range(FIELD.position.x, FIELD.end.x)
	if message_timer > 0.0:
		message_timer -= dt
	if phase == "playing" and not paused:
		_process_game(dt)
	queue_redraw()

func _process_game(dt: float) -> void:
	invuln = maxf(0.0, invuln - dt)
	dash_cooldown = maxf(0.0, dash_cooldown - dt)
	var move := Vector2(
		float(Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT)) - float(Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT)),
		float(Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN)) - float(Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP))
	)
	var speed := PLAYER_SPEED * (0.42 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	if move.length() > 0.0:
		player += move.normalized() * speed * dt
	player.x = clampf(player.x, FIELD.position.x + 16, FIELD.end.x - 16)
	player.y = clampf(player.y, FIELD.position.y + 30, FIELD.end.y - 17)
	fire_timer -= dt
	if fire_timer <= 0.0:
		fire_timer = 0.2
		_fire_all_weapons()
	if boss_active:
		_process_boss(dt)
	else:
		wave_timer += dt
		spawn_timer -= dt
		if spawn_timer <= 0.0 and wave_timer < 18.0:
			spawn_timer = maxf(0.48, 1.15 - wave * 0.1)
			_spawn_enemy()
		if wave_timer >= 18.0 and enemies.is_empty():
			if wave < 2:
				show_upgrade()
			else:
				_start_boss()
	_update_entities(dt)
	_update_collisions()
	_update_particles(dt)
	if player_hp <= 0:
		_enter_gameover()

func _spawn_enemy() -> void:
	var kind := rng.randi_range(0, 2)
	var p := Vector2(rng.randf_range(FIELD.position.x + 38, FIELD.end.x - 38), FIELD.position.y - 24)
	var data := {"p": p, "hp": 8, "max_hp": 8, "r": 14.0, "speed": 85.0, "kind": kind, "age": 0.0, "shot": rng.randf_range(1.0, 2.0)}
	if kind == 1:
		data.hp = 14
		data.max_hp = 14
		data.speed = 60.0
		data.r = 18.0
	elif kind == 2:
		data.hp = 7
		data.max_hp = 7
		data.speed = 105.0
		data.r = 12.0
	enemies.append(data)

func _start_boss() -> void:
	boss_active = true
	boss = {"p": Vector2(480, 112), "hp": 360.0, "max_hp": 360.0, "age": 0.0, "phase": 0.0}
	enemy_bullets.clear()
	message = "警告 · 敌方旗舰接近"
	message_timer = 3.0

func _process_boss(dt: float) -> void:
	if boss.hp <= 0:
		_finish_boss()
		return
	boss.age += dt
	boss.p.x = 480 + sin(boss.age * 0.8) * 145
	boss.p.y = 103 + sin(boss.age * 1.35) * 17
	boss_bullet_timer -= dt
	if boss_bullet_timer <= 0.0:
		boss_bullet_timer = 0.72 if boss.hp > 180 else 0.5
		var aim: Vector2 = (player - boss.p).normalized()
		var spokes := 7 if boss.hp > 180 else 11
		for i in range(spokes):
			var angle: float = aim.angle() + (float(i) - float(spokes - 1) / 2.0) * (0.17 if boss.hp > 180 else 0.13)
			_spawn_bullet(boss.p + Vector2(0, 28), Vector2.RIGHT.rotated(angle) * (155.0 if boss.hp > 180 else 195.0), 6.0, Color("ff668c"))
		if int(boss.age) % 5 == 0 and fmod(boss.age, 5.0) < 0.74:
			for side in [-1.0, 1.0]:
				_spawn_bullet(boss.p + Vector2(side * 45, 18), Vector2(side * 38, 205), 7.0, Color("ffb94d"))
	if boss.hp <= 0:
		_finish_boss()

func _finish_boss() -> void:
	if phase == "victory":
		return
	boss.hp = 0
	boss_active = false
	score += 5000
	_make_burst(boss.p, Color("ffbd5a"), 34)
	phase = "victory"
	_settle_run(true)
	ember += run_reward
	_save_save()
	message = "旗舰已击破 · 航线安全"
	message_timer = 10.0

func _spawn_bullet(pos: Vector2, velocity: Vector2, radius: float, color: Color) -> void:
	enemy_bullets.append({"p": pos, "v": velocity, "r": radius, "color": color, "graze": false})

func _update_entities(dt: float) -> void:
	for i in range(enemy_bullets.size() - 1, -1, -1):
		var b: Dictionary = enemy_bullets[i]
		b.p += b.v * dt
		if b.p.y > FIELD.end.y + 22 or b.p.x < FIELD.position.x - 22 or b.p.x > FIELD.end.x + 22:
			enemy_bullets.remove_at(i)
	for i in range(player_bullets.size() - 1, -1, -1):
		var b: Dictionary = player_bullets[i]
		if b.kind in ["seeker", "drone"]:
			var target := _nearest_enemy()
			if not target.is_empty(): b.v = (target.p - b.p).normalized() * 360.0
		b.p += b.v * dt
		if b.has("life"):
			b.life -= dt
		if b.p.y < FIELD.position.y - 30 or b.get("life", 1.0) <= 0.0:
			player_bullets.remove_at(i)
	for i in range(enemies.size() - 1, -1, -1):
		var e: Dictionary = enemies[i]
		e.age += dt
		e.p.y += e.speed * dt
		e.p.x += sin(e.age * 2.2 + e.p.y * 0.02) * 38 * dt
		e.shot -= dt
		if e.shot <= 0.0 and e.p.y < FIELD.end.y - 40:
			e.shot = 1.65 if e.kind == 1 else 2.2
			var count := 3 if e.kind == 1 else 1
			for n in range(count):
				var aim: Vector2 = (player - e.p).normalized()
				var angle: float = aim.angle() + (float(n) - float(count - 1) / 2.0) * 0.23
				_spawn_bullet(e.p + Vector2(0, 8), Vector2.RIGHT.rotated(angle) * (125 if e.kind == 1 else 145), 5.0, Color("ff668c"))
		if e.p.y > FIELD.end.y + 28:
			enemies.remove_at(i)

func _update_collisions() -> void:
	for i in range(player_bullets.size() - 1, -1, -1):
		var b: Dictionary = player_bullets[i]
		var hit := false
		if boss_active and boss.hp > 0 and b.p.distance_to(boss.p) < 37 + b.r:
			boss.hp -= b.d
			hit = true
			if b.has("blast") or b.kind == "arc": _weapon_splash(b, boss.p, -1)
			if boss.hp <= 0:
				_finish_boss()
		if not hit:
			for j in range(enemies.size() - 1, -1, -1):
				var e: Dictionary = enemies[j]
				if b.p.distance_to(e.p) < e.r + b.r:
					e.hp -= b.d
					hit = true
					if b.has("blast") or b.kind == "arc": _weapon_splash(b, e.p, j)
					if e.hp <= 0:
						score += 100 + e.kind * 50
						wave_kills += 1
						_make_burst(e.p, Color("69ddff"), 10)
						enemies.remove_at(j)
					break
		if hit:
			if b.kind == "rail" and int(b.get("pierce", 0)) > 0:
				b.pierce -= 1
				b.p.y -= 90.0
			else:
				player_bullets.remove_at(i)
	for i in range(enemy_bullets.size() - 1, -1, -1):
		var enemy_bullet: Dictionary = enemy_bullets[i]
		var distance := player.distance_to(enemy_bullet.p)
		if not enemy_bullet.graze and distance < enemy_bullet.r + 21 and distance > enemy_bullet.r + 8:
			enemy_bullet.graze = true
			dash_energy = minf(100.0, dash_energy + 9.0 * graze_bonus)
			score += 10
		var hit_radius: float = enemy_bullet.r + (7.0 if Input.is_key_pressed(KEY_SHIFT) else 15.0)
		if invuln <= 0 and distance < hit_radius:
			_damage_player()
			enemy_bullets.remove_at(i)
			break
	for j in range(enemies.size() - 1, -1, -1):
		var enemy: Dictionary = enemies[j]
		if invuln <= 0 and player.distance_to(enemy.p) < enemy.r + 13:
			_damage_player()
			enemies.remove_at(j)
			break

func _weapon_splash(bullet: Dictionary, impact: Vector2, direct_enemy_index: int) -> void:
	var radius := float(bullet.get("blast", 64.0 if bullet.kind == "arc" else 0.0))
	if radius <= 0.0: return
	var damage := maxi(1, int(bullet.d / 2))
	var affected := 0
	for j in range(enemies.size() - 1, -1, -1):
		if j == direct_enemy_index: continue
		var enemy: Dictionary = enemies[j]
		if impact.distance_to(enemy.p) <= radius:
			enemy.hp -= damage
			affected += 1
			if enemy.hp <= 0:
				score += 100 + enemy.kind * 50
				wave_kills += 1
				_make_burst(enemy.p, Color("69ddff"), 10)
				enemies.remove_at(j)
			if bullet.kind == "arc" and affected >= int(bullet.get("chain", 3)): break
	if boss_active and boss.hp > 0 and impact.distance_to(boss.p) <= radius:
		boss.hp -= damage
		if boss.hp <= 0: _finish_boss()

func _damage_player() -> void:
	player_hp = maxi(0, player_hp - 1)
	invuln = 1.25
	_make_burst(player, Color("65e9ff"), 16)
	message = "受击！装甲 -1"
	message_timer = 0.8

func try_dash() -> void:
	if dash_energy < 100.0 or dash_cooldown > 0.0:
		return
	var direction := Vector2.ZERO
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT): direction.x += 1
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT): direction.x -= 1
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN): direction.y += 1
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP): direction.y -= 1
	if direction == Vector2.ZERO: direction = Vector2.UP
	direction = direction.normalized()
	var start := player
	var finish := player + direction * 115
	finish.x = clampf(finish.x, FIELD.position.x + 16, FIELD.end.x - 16)
	finish.y = clampf(finish.y, FIELD.position.y + 30, FIELD.end.y - 17)
	for i in range(enemy_bullets.size() - 1, -1, -1):
		var b: Dictionary = enemy_bullets[i]
		if _distance_to_segment(b.p, start, finish) < 24:
			enemy_bullets.remove_at(i)
	for i in range(enemies.size() - 1, -1, -1):
		var e: Dictionary = enemies[i]
		if _distance_to_segment(e.p, start, finish) < e.r + 17:
			e.hp -= dash_damage
			if e.hp <= 0:
				score += 100 + e.kind * 50
				wave_kills += 1
				_make_burst(e.p, Color("69ddff"), 10)
				enemies.remove_at(i)
	player = finish
	dash_energy = 0.0
	dash_cooldown = 0.5
	invuln = maxf(invuln, 0.24)
	_make_burst(player, Color("73f6ff"), 12)
	if boss_active and _distance_to_segment(boss.p, start, finish) < 55:
		boss.hp -= dash_damage
		if boss.hp <= 0:
			_finish_boss()

func _distance_to_segment(point: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var t := clampf((point - a).dot(ab) / maxf(ab.length_squared(), 0.001), 0.0, 1.0)
	return point.distance_to(a + ab * t)

func _nearest_enemy() -> Dictionary:
	var best: Dictionary = {}
	var best_dist := INF
	for e in enemies:
		var d: float = player.distance_to(e.p)
		if d < best_dist:
			best = e
			best_dist = d
	if boss_active and boss.hp > 0:
		return boss
	return best

func show_upgrade() -> void:
	phase = "upgrade"
	wave += 1
	wave_timer = 0.0
	spawn_timer = 1.2
	upgrade_options.clear()
	var candidates := STAGE_UPGRADES.duplicate()
	for i in range(3):
		var index := rng.randi_range(0, candidates.size() - 1)
		upgrade_options.append(candidates[index])
		candidates.remove_at(index)

func choose_upgrade(index: int) -> void:
	if index < 0 or index >= upgrade_options.size():
		return
	var module: Dictionary = upgrade_options[index]
	match module.key:
		"damage": player_damage += 2
		"health":
			player_max_hp += 1
			player_hp = mini(player_max_hp, player_hp + 1)
		"energy": dash_energy = 100.0
	phase = "route"
	message = "强化完成：" + module.name
	message_timer = 1.8

func choose_route(index: int) -> void:
	if index == 0:
		player_hp = mini(player_max_hp, player_hp + 1)
		spawn_timer = 1.2
		message = "补给线 · 装甲修复"
	else:
		dash_energy = minf(100.0, dash_energy + 25.0)
		spawn_timer = 0.65
		message = "风暴线 · 能量回收，敌群逼近"
	phase = "playing"
	_save_checkpoint()
	message_timer = 2.0

func _save_checkpoint() -> void:
	checkpoint = {"player_hp": player_hp, "player_max_hp": player_max_hp, "dash_energy": dash_energy,
		"dash_damage": dash_damage, "player_damage": player_damage,
		"graze_bonus": graze_bonus, "wave": wave, "score": score,
		"wave_kills": wave_kills}

func _enter_gameover() -> void:
	if phase == "gameover": return
	phase = "gameover"
	_settle_run(false)

func _settle_run(won: bool) -> void:
	if reward_claimed: return
	reward_claimed = true
	run_reward = maxi(5, int(score / 100) + wave * 12 + wave_kills * 2 + (100 if won else 0))

func return_to_hangar() -> void:
	if phase != "gameover": return
	if not reward_claimed: _settle_run(false)
	ember += run_reward
	hangar_notice = "本次带回 %d 余烬" % run_reward
	_save_save()
	phase = "title"
	paused = false

func return_to_title_after_victory() -> void:
	if phase != "victory": return
	hangar_notice = "任务完成 · 奖励 %d 余烬已存入机库" % run_reward
	phase = "title"
	paused = false

func retry_checkpoint() -> void:
	if phase != "gameover" or checkpoint.is_empty(): return
	reward_claimed = false
	run_reward = 0
	player = Vector2(480, 445)
	player_hp = checkpoint.player_hp
	player_max_hp = checkpoint.player_max_hp
	dash_energy = checkpoint.dash_energy
	dash_damage = checkpoint.dash_damage
	player_damage = checkpoint.player_damage
	graze_bonus = checkpoint.graze_bonus
	wave = checkpoint.wave
	score = checkpoint.score
	wave_kills = checkpoint.wave_kills
	invuln = 1.5
	seek_timer = 0.0
	fire_timer = 0.0
	enemies.clear()
	enemy_bullets.clear()
	player_bullets.clear()
	particles.clear()
	boss.clear()
	boss_active = false
	wave_timer = 0.0
	spawn_timer = 0.8
	phase = "playing"
	paused = false
	message = "检查点重试 · 航段 %02d" % (wave + 1)
	message_timer = 2.2

func buy_hangar_upgrade() -> void:
	if ember < 100:
		hangar_notice = "余烬不足：永久装甲需要 100"
	else:
		ember -= 100
		hangar_notice = "已购入永久装甲：后续出击多 1 格生命"
		permanent_armor += 1
		player_max_hp = 3 + permanent_armor
	_save_save()

func _weapon_key(index: int) -> String:
	return str(WEAPONS[index].key)

func _active_weapon_summary() -> String:
	var names := ["基础脉冲炮"]
	for weapon in WEAPONS:
		var level := _weapon_level(str(weapon.key))
		if level > 0: names.append("%s ×%d" % [weapon.name, level])
	return "\n".join(names)

func _weapon_level(key: String) -> int:
	return int(weapon_levels.get(key, 0))

func adjust_weapon(amount: int) -> void:
	var key := _weapon_key(store_selection)
	var level := _weapon_level(key)
	if amount > 0:
		if level >= 5:
			hangar_notice = "该武器已达到 5 级上限"
			return
		var price := 60 + level * 40
		if ember < price:
			hangar_notice = "余烬不足：升级需要 %d" % price
			return
		ember -= price
		weapon_levels[key] = level + 1
		hangar_notice = "%s 叠加到 %d 单位，已自动加入出击" % [WEAPONS[store_selection].name, level + 1]
	else:
		if level <= 0:
			hangar_notice = "这件武器还没有购买"
			return
		var refund := 60 + (level - 1) * 40
		ember += refund
		weapon_levels[key] = level - 1
		hangar_notice = "已出售 1 单位 %s，退回 %d 余烬" % [WEAPONS[store_selection].name, refund]
	_save_save()

func _handle_store_click(pos: Vector2) -> void:
	for i in range(WEAPONS.size()):
		var col := i % 3
		var row := int(i / 3)
		var rect := Rect2(126 + col * 242, 134 + row * 174, 218, 152)
		if rect.has_point(pos):
			store_selection = i
			if Rect2(rect.position + Vector2(124, 101), Vector2(38, 32)).has_point(pos): adjust_weapon(-1)
			elif Rect2(rect.position + Vector2(169, 101), Vector2(38, 32)).has_point(pos): adjust_weapon(1)
			return

func _fire_all_weapons() -> void:
	_fire_weapon("pulse", 1)
	for weapon in WEAPONS:
		var level := _weapon_level(str(weapon.key))
		if level > 0: _fire_weapon(str(weapon.key), level)

func _fire_weapon(weapon_key: String, level: int) -> void:
	var damage := player_damage + (level - 1) * 2
	match weapon_key:
		"scatter":
			var shot_count := level + 2
			for i in range(shot_count):
				var angle := (float(i) - float(shot_count - 1) / 2.0) * 0.13
				player_bullets.append({"p": player + Vector2(0, -16), "v": Vector2.UP.rotated(angle) * 470, "r": 4.0, "d": damage, "kind": "scatter"})
		"rail":
			for i in range(level):
				var offset := (float(i) - float(level - 1) / 2.0) * 11.0
				player_bullets.append({"p": player + Vector2(offset, -20), "v": Vector2(0, -650), "r": 6.0, "d": damage * 2, "kind": "rail", "pierce": 2 + level})
		"seeker":
			var target := _nearest_enemy()
			var direction: Vector2 = Vector2.UP if target.is_empty() else (target.p - player).normalized()
			for i in range(level + 1):
				player_bullets.append({"p": player + Vector2((float(i) - float(level) / 2.0) * 10, -8), "v": direction * 360, "r": 5.0, "d": damage, "kind": "seeker", "life": 2.4})
		"drone":
			var target := _nearest_enemy()
			var direction: Vector2 = Vector2.UP if target.is_empty() else (target.p - player).normalized()
			var drones := _get_drone_positions()
			for drone_position in drones:
				player_bullets.append({"p": drone_position, "v": direction * 360, "r": 5.0, "d": damage, "kind": "drone", "life": 2.4})
		"arc":
			var bolts := 1 + int((level - 1) / 2)
			for i in range(bolts):
				var angle := (float(i) - float(bolts - 1) / 2.0) * 0.12
				player_bullets.append({"p": player + Vector2(0, -20), "v": Vector2.UP.rotated(angle) * 540, "r": 5.0, "d": damage, "kind": "arc", "chain": 2 + level})
		"rocket":
			for i in range(level):
				var angle := (float(i) - float(level - 1) / 2.0) * 0.12
				player_bullets.append({"p": player + Vector2(0, -20), "v": Vector2.UP.rotated(angle) * 390, "r": 7.0, "d": damage * 2, "kind": "rocket", "blast": 48.0 + level * 5})
		_:
			player_bullets.append({"p": player + Vector2(0, -21), "v": Vector2(0, -560), "r": 4.0, "d": damage, "kind": "pulse"})
func _get_drone_positions() -> Array[Vector2]:
	var positions: Array[Vector2] = []
	var count := _weapon_level("drone")
	if count <= 0: return positions
	var orbit_angle := float(Time.get_ticks_msec()) * 0.0014
	for i in range(count):
		var angle := orbit_angle + TAU * float(i) / float(count)
		positions.append(player + Vector2(cos(angle) * 30.0, sin(angle) * 19.0))
	return positions

func _load_save() -> void:
	if not FileAccess.file_exists(SAVE_PATH): return
	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null: return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed is Dictionary:
		ember = int(parsed.get("ember", 0))
		permanent_armor = int(parsed.get("permanent_armor", 0))
		player_max_hp = 3 + permanent_armor
		weapon_levels = parsed.get("weapon_levels", {"pulse": 1})

func _save_save() -> void:
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null: return
	file.store_string(JSON.stringify({"ember": ember, "permanent_armor": permanent_armor, "weapon_levels": weapon_levels}))

func _update_particles(dt: float) -> void:
	for i in range(particles.size() - 1, -1, -1):
		var p: Dictionary = particles[i]
		p.p += p.v * dt
		p.life -= dt
		if p.life <= 0.0:
			particles.remove_at(i)

func _make_burst(pos: Vector2, color: Color, count: int) -> void:
	for i in range(count):
		var angle := rng.randf_range(0.0, TAU)
		var speed := rng.randf_range(35.0, 180.0)
		particles.append({"p": pos, "v": Vector2.RIGHT.rotated(angle) * speed, "life": rng.randf_range(0.18, 0.5), "color": color, "r": rng.randf_range(1.5, 4.0)})

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, VIEW_SIZE), Color("070d1c"))
	for star in stars:
		draw_circle(star.p, star.s, Color(0.38, 0.67, 0.88, 0.27 + star.s * 0.17))
	draw_rect(FIELD, Color("0c1830"))
	draw_rect(FIELD, Color("2e5177"), false, 2.0)
	for i in range(11):
		var y := fmod(float(i) * 53.0 + Time.get_ticks_msec() * 0.045, FIELD.size.y)
		draw_line(Vector2(FIELD.position.x + 2, y), Vector2(FIELD.position.x + 8, y + 18), Color(0.26, 0.56, 0.8, 0.1), 1)
	for b in enemy_bullets:
		draw_circle(b.p, b.r + 3, Color(b.color.r, b.color.g, b.color.b, 0.16))
		draw_circle(b.p, b.r, b.color)
		draw_circle(b.p, b.r * 0.4, Color("fff2d4"))
	for b in player_bullets:
		var c := Color("f8efad")
		if b.kind in ["seek", "seeker", "drone"]: c = Color("a4ffb6")
		elif b.kind == "rail": c = Color("8beaff")
		elif b.kind == "rocket": c = Color("ff9e5d")
		elif b.kind == "arc": c = Color("72f7ff")
		draw_rect(Rect2(b.p - Vector2(2, 8), Vector2(4, 14)), c)
	for e in enemies:
		_draw_enemy(e)
	if boss_active:
		_draw_boss()
	for p in particles:
		draw_circle(p.p, p.r * p.life * 2.5, Color(p.color.r, p.color.g, p.color.b, minf(1.0, p.life * 3)))
	if phase in ["playing", "upgrade", "victory", "gameover"]:
		_draw_player()
		_draw_hud()
	if phase == "title": _draw_title()
	elif phase == "store": _draw_store()
	elif phase == "upgrade": _draw_upgrade()
	elif phase == "route": _draw_route()
	elif phase == "gameover": _draw_end(false)
	elif phase == "victory": _draw_end(true)
	if paused: _draw_pause()
	if message_timer > 0 and phase == "playing":
		_draw_text(message, Vector2(FIELD.position.x, 80), 20, Color("bfefff"), HORIZONTAL_ALIGNMENT_CENTER, FIELD.size.x)

func _draw_player() -> void:
	if invuln > 0 and int(Time.get_ticks_msec() / 80) % 2 == 0: return
	var body := PackedVector2Array([player + Vector2(0, -18), player + Vector2(-13, 13), player + Vector2(0, 8), player + Vector2(13, 13)])
	draw_colored_polygon(body, Color("72eaff"))
	draw_colored_polygon(PackedVector2Array([player + Vector2(0, -11), player + Vector2(-5, 8), player + Vector2(5, 8)]), Color("e7fdff"))
	for drone_position in _get_drone_positions():
		draw_line(player, drone_position, Color(0.25, 0.86, 1.0, 0.28), 1.0)
		draw_circle(drone_position, 9.0, Color(0.2, 0.9, 1.0, 0.15))
		draw_colored_polygon(PackedVector2Array([drone_position + Vector2(0, -7), drone_position + Vector2(-7, 4), drone_position + Vector2(0, 7), drone_position + Vector2(7, 4)]), Color("6ff3dc"))
		draw_circle(drone_position, 2.0, Color("f3fff8"))
	draw_circle(player, 4.0 if Input.is_key_pressed(KEY_SHIFT) else 0.0, Color("ffcf70"))
	if Input.is_key_pressed(KEY_SHIFT):
		draw_arc(player, 8, 0, TAU, 24, Color("ffe58c"), 1.5)

func _draw_enemy(e: Dictionary) -> void:
	var p: Vector2 = e.p
	var c := Color("ff6389") if e.kind == 1 else (Color("ffb15c") if e.kind == 2 else Color("ca7aff"))
	var points := PackedVector2Array([p + Vector2(0, 17), p + Vector2(-16, -10), p, p + Vector2(16, -10)])
	if e.kind == 1:
		points = PackedVector2Array([p + Vector2(-19, -12), p + Vector2(0, -17), p + Vector2(19, -12), p + Vector2(13, 13), p + Vector2(0, 18), p + Vector2(-13, 13)])
	draw_colored_polygon(points, c)
	draw_line(p + Vector2(-e.r, -22), p + Vector2(e.r, -22), Color("4b284b"), 3)
	draw_line(p + Vector2(-e.r, -22), p + Vector2(-e.r + 2 * e.r * e.hp / e.max_hp, -22), Color("9affb5"), 3)

func _draw_boss() -> void:
	var p: Vector2 = boss.p
	var points := PackedVector2Array([p + Vector2(0, 34), p + Vector2(-56, 10), p + Vector2(-72, -18), p + Vector2(-25, -12), p + Vector2(0, -34), p + Vector2(25, -12), p + Vector2(72, -18), p + Vector2(56, 10)])
	draw_colored_polygon(points, Color("cc547d"))
	draw_colored_polygon(PackedVector2Array([p + Vector2(-9, -13), p + Vector2(0, -25), p + Vector2(9, -13), p + Vector2(0, 12)]), Color("ffe292"))
	draw_line(Vector2(FIELD.position.x + 35, 31), Vector2(FIELD.end.x - 35, 31), Color("422638"), 8)
	draw_line(Vector2(FIELD.position.x + 35, 31), Vector2(FIELD.position.x + 35 + (FIELD.size.x - 70) * boss.hp / boss.max_hp, 31), Color("ff5a82"), 8)
	_draw_text("旗舰 · " + str(int(boss.hp)) + " / " + str(int(boss.max_hp)), Vector2(FIELD.position.x, 17), 13, Color("ffd5df"), HORIZONTAL_ALIGNMENT_CENTER, FIELD.size.x)

func _draw_hud() -> void:
	draw_rect(Rect2(24, 26, 210, 490), Color("101a2b"))
	draw_rect(Rect2(24, 26, 210, 490), Color("294565"), false, 1.0)
	_draw_text("EMBER ROUTE", Vector2(42, 55), 17, Color("75e8ff"))
	_draw_text("余 烬 航 线", Vector2(42, 82), 20, Color("f1f8ff"))
	draw_line(Vector2(42, 98), Vector2(214, 98), Color("34516f"), 1)
	_draw_text("SCORE", Vector2(42, 129), 11, Color("7796b7"))
	_draw_text("%07d" % score, Vector2(42, 157), 23, Color("fff1c2"))
	_draw_text("装甲", Vector2(42, 199), 13, Color("a8c7e0"))
	for i in range(player_max_hp):
		draw_rect(Rect2(42 + i * 27, 212, 20, 8), Color("69e7ff") if i < player_hp else Color("26394e"))
	_draw_text("擦弹能量", Vector2(42, 252), 13, Color("a8c7e0"))
	draw_rect(Rect2(42, 265, 170, 10), Color("23354b"))
	draw_rect(Rect2(42, 265, 170 * dash_energy / 100, 10), Color("ffca69"))
	_draw_text("折跃就绪" if dash_energy >= 100 else "贴近弹幕充能", Vector2(42, 294), 12, Color("ffdb93"))
	_draw_text("航段 %02d" % (wave + 1), Vector2(42, 340), 16, Color("c8e9ff"))
	_draw_text("击破 %03d" % wave_kills, Vector2(42, 364), 12, Color("829db8"))
	_draw_text("配置", Vector2(42, 410), 13, Color("a8c7e0"))
	var config := _active_weapon_summary()
	_draw_text(config, Vector2(42, 433), 12, Color("8fe2ef"), HORIZONTAL_ALIGNMENT_LEFT, 170)
	draw_rect(Rect2(726, 26, 210, 490), Color("101a2b"))
	draw_rect(Rect2(726, 26, 210, 490), Color("294565"), false, 1.0)
	_draw_text("飛 行 指 南", Vector2(746, 60), 16, Color("e6f7ff"))
	_draw_text("WASD / 方向键\n移动战机\n\n按住 Shift\n低速精控与小判定\n\n自动发射\n无需按射击键\n\nK / X\n折跃大招（满能）\n\nEsc\n暂停", Vector2(746, 96), 13, Color("9bb6d0"), HORIZONTAL_ALIGNMENT_LEFT, 170)
	draw_line(Vector2(746, 352), Vector2(916, 352), Color("34516f"), 1)
	_draw_text("本次任务", Vector2(746, 379), 12, Color("7796b7"))
	_draw_text("所有已购武器同时自动齐射\n擦弹为折跃充能\nK / X 释放折跃大招", Vector2(746, 404), 12, Color("78dbea"), HORIZONTAL_ALIGNMENT_LEFT, 170)

func _draw_title() -> void:
	draw_rect(Rect2(0, 0, 960, 540), Color(0.015, 0.03, 0.07, 0.87))
	_draw_text("余 烬 航 线", Vector2(210, 176), 42, Color("e9faff"), HORIZONTAL_ALIGNMENT_CENTER, 540)
	_draw_text("EMBER ROUTE", Vector2(210, 212), 16, Color("68ddff"), HORIZONTAL_ALIGNMENT_CENTER, 540)
	_draw_text("贴着弹幕飞行，积攒能量；折跃穿过火网，反击旗舰。", Vector2(150, 260), 17, Color("b6cde1"), HORIZONTAL_ALIGNMENT_CENTER, 660)
	_draw_text("WASD 移动  ·  Shift 精控  ·  自动射击  ·  K / X 折跃大招", Vector2(150, 302), 14, Color("91a9c2"), HORIZONTAL_ALIGNMENT_CENTER, 660)
	_draw_text("机库余烬  %d" % ember, Vector2(150, 350), 17, Color("ffcf72"), HORIZONTAL_ALIGNMENT_CENTER, 660)
	_draw_text("按 B 进入商店：购买的武器会同时自动出击", Vector2(150, 379), 14, Color("b6cde1"), HORIZONTAL_ALIGNMENT_CENTER, 660)
	_draw_text("按 Enter 或 Space 开始", Vector2(150, 421), 20, Color("ffcf72"), HORIZONTAL_ALIGNMENT_CENTER, 660)
	_draw_text(hangar_notice if hangar_notice != "" else "MVP 原型 · 单局约 2–3 分钟", Vector2(150, 458), 12, Color("91a9c2"), HORIZONTAL_ALIGNMENT_CENTER, 660)

func _draw_store() -> void:
	draw_rect(Rect2(0, 0, 960, 540), Color("080f20", 0.98))
	_draw_text("机 库 商 店", Vector2(126, 58), 30, Color("e9faff"))
	_draw_text("余烬 %d   ·   所有已购买武器都会同时出击" % ember, Vector2(126, 91), 15, Color("ffcf72"))
	_draw_text("点击卡片选择 · − 出售一级并全额退款 · + 购买一级（每件最多 5 级）", Vector2(126, 116), 13, Color("9bb6d0"))
	for i in range(WEAPONS.size()):
		var col := i % 3
		var row := int(i / 3)
		var rect := Rect2(126 + col * 242, 134 + row * 174, 218, 152)
		var key := _weapon_key(i)
		var level := _weapon_level(key)
		var selected := i == store_selection
		draw_rect(rect, Color("182a40") if selected else Color("111f32"))
		var border := Color("ffcf72") if selected else (Color("7ce7ff") if level > 0 else Color("3c5b78"))
		draw_rect(rect, border, false, 2.0)
		_draw_text("[%d] %s" % [i + 1, WEAPONS[i].name], rect.position + Vector2(12, 27), 16, Color("8feaff"))
		_draw_text("叠加单位 %d / 5 · %s" % [level, "已加入齐射" if level > 0 else "未购买"], rect.position + Vector2(12, 54), 12, Color("ffcf72"))
		_draw_text(WEAPONS[i].desc, rect.position + Vector2(12, 78), 11, Color("bdd1df"))
		draw_rect(Rect2(rect.position + Vector2(124, 101), Vector2(38, 32)), Color("273b50"))
		draw_rect(Rect2(rect.position + Vector2(169, 101), Vector2(38, 32)), Color("42351e"))
		_draw_text("−", rect.position + Vector2(137, 124), 19, Color("e9faff"))
		_draw_text("+", rect.position + Vector2(182, 124), 19, Color("ffcf72"))
		var next_cost := 60 + level * 40
		_draw_text("退 %d" % (60 + (level - 1) * 40) if level > 0 else "—", rect.position + Vector2(12, 122), 11, Color("82d7bd"))
		_draw_text("购 %d" % next_cost if level < 5 else "满级", rect.position + Vector2(57, 122), 11, Color("ffcf72"))
	_draw_text("按 1–6 选择武器 · ← / → 或 − / + 调整等级 · Esc / B 返回 · Q 购买装甲（100）", Vector2(126, 504), 13, Color("9bb6d0"))

func _draw_upgrade() -> void:
	draw_rect(Rect2(0, 0, 960, 540), Color(0.015, 0.03, 0.07, 0.88))
	_draw_text("航段完成", Vector2(180, 114), 30, Color("eafaff"), HORIZONTAL_ALIGNMENT_CENTER, 600)
	_draw_text("选择一项强化，准备下一段航程", Vector2(180, 153), 16, Color("8eb3ce"), HORIZONTAL_ALIGNMENT_CENTER, 600)
	for i in range(upgrade_options.size()):
		var x := 168 + i * 213
		draw_rect(Rect2(x, 205, 194, 174), Color("13253a"))
		draw_rect(Rect2(x, 205, 194, 174), Color("4c7799"), false, 2)
		_draw_text("[ %d ]" % (i + 1), Vector2(x + 12, 239), 16, Color("ffcd70"))
		_draw_text(upgrade_options[i].name, Vector2(x + 12, 281), 19, Color("8feaff"))
		_draw_text(upgrade_options[i].desc, Vector2(x + 12, 320), 13, Color("bdd1df"), HORIZONTAL_ALIGNMENT_LEFT, 168)
	_draw_text("按 1 / 2 / 3 选择强化", Vector2(180, 432), 18, Color("ffcf72"), HORIZONTAL_ALIGNMENT_CENTER, 600)

func _draw_route() -> void:
	draw_rect(Rect2(0, 0, 960, 540), Color(0.015, 0.03, 0.07, 0.88))
	_draw_text("选择下一条航线", Vector2(180, 136), 30, Color("eafaff"), HORIZONTAL_ALIGNMENT_CENTER, 600)
	_draw_text("不同路线会改变补给与下一段遭遇节奏", Vector2(180, 174), 16, Color("8eb3ce"), HORIZONTAL_ALIGNMENT_CENTER, 600)
	draw_rect(Rect2(212, 226, 238, 144), Color("13253a"))
	draw_rect(Rect2(212, 226, 238, 144), Color("4c7799"), false, 2)
	draw_rect(Rect2(510, 226, 238, 144), Color("2a1d31"))
	draw_rect(Rect2(510, 226, 238, 144), Color("a35578"), false, 2)
	_draw_text("[ 1 ] 补给线", Vector2(232, 266), 20, Color("8feaff"))
	_draw_text("修复 1 格装甲\n遭遇节奏较缓", Vector2(232, 300), 14, Color("bdd1df"), HORIZONTAL_ALIGNMENT_LEFT, 198)
	_draw_text("[ 2 ] 风暴线", Vector2(530, 266), 20, Color("ffad7b"))
	_draw_text("回收 25% 折跃能量\n敌群来得更快", Vector2(530, 300), 14, Color("e4c8d0"), HORIZONTAL_ALIGNMENT_LEFT, 198)
	_draw_text("按 1 / 2 选择航线", Vector2(180, 427), 18, Color("ffcf72"), HORIZONTAL_ALIGNMENT_CENTER, 600)

func _draw_end(won: bool) -> void:
	draw_rect(Rect2(0, 0, 960, 540), Color(0.015, 0.03, 0.07, 0.88))
	_draw_text("任 务 完 成" if won else "战 机 失 联", Vector2(180, 188), 38, Color("8ff0d0") if won else Color("ff8298"), HORIZONTAL_ALIGNMENT_CENTER, 600)
	_draw_text("敌方旗舰已被击破，回收船队安全脱离。" if won else "战机失去动力。再试一次，航线仍在等你。", Vector2(180, 242), 17, Color("c5d8e6"), HORIZONTAL_ALIGNMENT_CENTER, 600)
	_draw_text("最终得分  %07d" % score, Vector2(180, 300), 22, Color("fff0bb"), HORIZONTAL_ALIGNMENT_CENTER, 600)
	if won:
		_draw_text("任务奖励 +%d 余烬 · 已存入机库" % run_reward, Vector2(180, 350), 17, Color("ffcf72"), HORIZONTAL_ALIGNMENT_CENTER, 600)
		_draw_text("按 Enter / Space / Esc 返回标题画面", Vector2(180, 397), 16, Color("ffcf72"), HORIZONTAL_ALIGNMENT_CENTER, 600)
	else:
		_draw_text("任务奖励 +%d 余烬 · 选择去向" % run_reward, Vector2(180, 343), 17, Color("ffcf72"), HORIZONTAL_ALIGNMENT_CENTER, 600)
		_draw_text("[ 1 ] 返回机库并领取奖励      [ 2 ] 从本航段检查点重试", Vector2(180, 397), 15, Color("ffcf72"), HORIZONTAL_ALIGNMENT_CENTER, 600)

func _draw_pause() -> void:
	draw_rect(Rect2(0, 0, 960, 540), Color(0.015, 0.03, 0.07, 0.76))
	_draw_text("暂停", Vector2(180, 244), 34, Color("e9faff"), HORIZONTAL_ALIGNMENT_CENTER, 600)
	_draw_text("按 Esc 继续", Vector2(180, 290), 16, Color("9ab8ce"), HORIZONTAL_ALIGNMENT_CENTER, 600)

func _draw_text(text: String, pos: Vector2, size: int, color: Color, align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT, width: float = -1.0) -> void:
	var font := ThemeDB.fallback_font
	if font:
		draw_string(font, pos, text, align, width, size, color)
