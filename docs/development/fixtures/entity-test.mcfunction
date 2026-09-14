gamemode creative @p
difficulty peaceful
gamerule minecraft:advance_time false
gamerule minecraft:advance_weather false
time of minecraft:overworld set 2000
weather clear
kill @e[tag=rt_entity_test]
fill 180 158 180 205 174 205 air
fill 180 158 180 205 158 205 iron_block
setblock 201 161 201 barrier
setblock 196 161 196 barrier
setblock 193 161 196 barrier
summon minecraft:cow 196.5 162 196.5 {Tags:["rt_entity_test"],NoAI:1b,Silent:1b,PersistenceRequired:1b,Invulnerable:1b,Rotation:[135f,0f]}
tp @p 201.5 162 201.5 135 30
