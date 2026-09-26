# Por qué hay scripts Python antes que código Z80

Este documento explica qué hace cada script en `tools/`, qué pregunta responde
en el flujo de trabajo de PocketFever, y por qué se escribe primero en Python
en vez de directamente en ensamblador Z80. No documenta el motor del juego en
sí (para eso está `CLAUDE.md`); documenta el **método**.

## La distinción de fondo: espacio latente vs espacio determinista

El razonamiento detrás de esto no es específico de PocketFever — es una regla
general que sigo en todos los proyectos (está en mi configuración de usuario,
no en el repo): **si la misma pregunta, hecha dos veces con la misma entrada,
tiene que dar la misma respuesta correcta por definición, eso es trabajo
determinista, no trabajo de razonamiento.** Aritmética, conversión de
unidades, simulación numérica, búsqueda de constantes que cumplan una
restricción — todo eso es determinista. Hacerlo "a ojo" mentalmente (en lo
que llamo espacio latente) es la forma más cara y menos fiable de resolverlo:
cuesta tokens de razonamiento, no es reproducible, y no es inspeccionable —
si me equivoco, no hay manera de que tú (o yo, releyendo después) descubra
dónde.

Escribir un script en cambio es barato una sola vez y después **se convierte
en la restricción que me impide equivocarme la próxima vez**. Ese es el
patrón que se repite en los cuatro scripts de `tools/`: cada uno nació porque
en algún momento del desarrollo necesité fijar una constante (fricción,
velocidad, ritmo de giro, alcance de la línea de puntería) y la alternativa a
escribir el script era, literalmente, adivinar un número, compilar,
cargarlo en el emulador, mirar si "se veía bien", y repetir — un ciclo de
varios minutos por intento, sin ninguna garantía de que el número elegido
generalizara a las 64 direcciones o a los distintos tamaños de bola.

## Por qué no directamente en Z80

Z80 no tiene aritmética en punto flotante, no tiene trigonometría, y
depurarlo significa compilar, arrancar un emulador (AmSpiriT-Lite, headless,
vía HTTP+Lua) y leer bytes de memoria o comparar píxeles de una captura de
pantalla. Cada iteración de "prueba un valor, mira qué pasa" en Z80 cuesta
minutos reales (compilación + arranque de emulador + verificación). En
Python la misma iteración cuesta milisegundos y puedo probar las 64
direcciones y todos los tamaños de bola relevantes en un solo `for`, no una
combinación a la vez.

Además, todos estos módulos usan aritmética en **punto fijo 8.8** (un entero
de 16 bits donde el byte alto es la parte entera y el bajo la fracción,
porque el Z80 no tiene coma flotante). Es fácil escribir esa aritmética mal
sin darse cuenta — un desbordamiento de 16 bits, un redondeo que se acumula,
una división que trunca en la dirección equivocada. Escribir la MISMA
aritmética en Python primero, con enteros de precisión arbitraria y
`assert`, hace visibles esos errores antes de tocar una sola línea de Z80: si
el modelo en Python ya falla (overflow, redondeo raro, un valor fuera de
rango), sé que la versión Z80 fallaría exactamente igual, y lo sé gratis, sin
compilar nada.

Por último, cada script termina siendo **la referencia contra la que el test
real (`tests/*.py`, que sí arranca el DSK compilado en el emulador) compara
el binario compilado**. No es solo una herramienta de diseño de una vez: es
el contrato que el test automatizado usa para decir "el Z80 hace exactamente
esto, no aproximadamente esto".

## Los cuatro scripts

### `tools/gen_shot_table.py` — genera la tabla de 64 direcciones

**Qué hace:** para cada una de las 64 direcciones (`DIRECTIONS = 64`), calcula
el vector `(dx, dy)` en punto fijo 8.8 que representa esa dirección a una
velocidad de referencia (`STEP = 64`). Escribe el resultado como
`src/game/shot_table.s`, un archivo `.s` con 64 líneas `.dw dx, dy` — datos
puros, sin lógica.

**Por qué en Python y no en Z80:** el cálculo necesita `cos()` y `sin()`. El
Z80 no tiene ninguna instrucción de trigonometría; implementar seno/coseno en
ensamblador (por CORDIC, por tabla con interpolación, etc.) sería mucho más
código, más lento en tiempo de ejecución, y para qué — el ángulo de cada
dirección es una constante conocida en tiempo de compilación, nunca cambia
mientras el juego corre. La tabla generada es literal: 64 pares de números
ya calculados. El Z80 nunca hace trigonometría, ni en V.001 ni en V.016;
simplemente lee `shot_directions[indice]` de una tabla que Python escribió
una vez.

Hay un detalle no obvio que justifica aún más hacerlo en Python:
**corrección de aspecto**. El Mode 0 de la CPC tiene píxeles más anchos que
altos — el `dx` de cada dirección se divide por `PIXEL_ASPECT = 2*132/160 =
1.65` para que, en pantalla, todas las direcciones recorran la misma
distancia real (si no se corrigiera, "derecha" se vería más rápida que
"abajo" aunque ambas usaran el mismo número de líneas de código). Ese `1.65`
sale de las dimensions del tapete (`TABLE_HEIGHT_PX`/`TABLE_WIDTH_PX`), así
que el script lo relee del propio código en vez de tenerlo hardcodeado dos
veces.

### `tools/friction_model.py` — compara modelos de fricción

**Qué hace:** simula, en punto fijo 8.8 exactamente como lo haría el Z80, una
bola rodando libremente (sin bandas) desde cada una de las 64 direcciones y
cada potencia de tiro posible, hasta que se para. Compara dos estrategias de
fricción — "por eje" (restar una constante a cada componente vx/vy por
separado) contra "por dirección de desplazamiento" (restar en el eje
dominante, y una fracción proporcional en el otro) — y para cada una reporta
cuánto se desvía la trayectoria real de la línea recta ideal.

**Por qué en Python primero:** esto no es una constante única, es una
**comparación entre dos algoritmos** antes de decidir cuál implementar. La
versión "por eje" resultó doblar hasta 20° en tiros diagonales (confirmado
por el modelo, no por prueba visual) — un defecto que a simple vista en el
emulador es difícil de cuantificar ("¿se curva un poco o mucho? ¿es peor en
diagonal que en horizontal?"), pero que el modelo mide en grados exactos
para las 64 direcciones y las 9 potencias en un instante. Decidir en Z80
directamente hubiera significado programar AMBAS versiones en ensamblador,
compilar las dos, y comparar visualmente en el emulador — mucho más caro y
mucho menos preciso que comparar dos funciones Python.

Una vez elegida la estrategia ("por dirección de desplazamiento", con
`PHYS_FRICTION = 4`), el mismo script queda como la referencia que
`tests/physics_test.py` usa para verificar que el Z80 realmente construido
se comporta así (el test arranca el DSK real, dispara tiros conocidos, y
compara el punto de parada real contra lo que el modelo predijo).

### `tools/turn_model.py` — dimensiona la rampa de giro del cursor

**Qué hace:** modela cuántos frames tarda en avanzar un paso de dirección
según cuánto tiempo lleva mantenida la tecla de cursor, con una rampa por
etapas (`STAGES`: empieza lento — preciso — y se acelera cuanto más se
mantiene pulsada). Da dos funciones complementarias: `simulate(pasos)`
(cuántos frames hacen falta para N pasos) y `steps_completed(frames)` (cuántos
pasos se han dado en N frames, la inversa).

**Por qué en Python:** diseñar la rampa es un problema de **ajuste de
parámetros** — ¿cuántas etapas, con qué umbrales, con qué ritmo cada una? Se
puede iterar sobre `STAGES` y ver al instante "una vuelta completa (64 pasos)
tarda 2 s mantenido, contra 7.7 s con un ritmo plano" sin compilar nada. Ese
mismo ajuste hecho probando valores en Z80 real habría significado: cambiar
una constante, recompilar, arrancar el emulador, mantener una tecla con un
script y cronometrar — por cada candidato de ritmo.

Hay una razón adicional, más sutil, para necesitar el modelo con precisión
exacta: los tests de este proyecto (`tests/turn_test.py`) verifican el
comportamiento real del Z80 comparándolo frame a frame contra
`steps_completed()`. Descubrí durante esta sesión que el emulador
(AmSpiriT-Lite) tiene una lentitud de registro de teclado variable (1-2
frames) entre "se pulsa la tecla" y "el juego la ve" — sin el modelo exacto
como referencia, sería imposible distinguir "el Z80 tiene un bug en la
rampa" de "el emulador tardó un frame de más en registrar la tecla". El
modelo permite calibrar ese desfase y verificar la lógica real por
separado del ruido del emulador.

### `tools/aim_model.py` — geometría de la línea de puntería (el más nuevo)

**Qué hace hoy (V.016):** calcula, para cualquier dirección e índice de
tiro, los puntos exactos donde se dibujan los guiones (`dashes`) de la línea
XOR de puntería — incluyendo el **rebote en las bandas**, que es la parte
nueva de esta sesión. También comprueba, antes de escribir una sola línea de
Z80, que la aritmética de 16 bits del acumulador no desborda
(`max_raw_magnitude`) y que el algoritmo de reflexión seleccionado nunca
necesita más de un "pliegue" (`check_single_wrap_margin`) — una garantía
matemática que el Z80 explota para no tener que programar un bucle de módulo
genérico, solo una resta condicional.

**Por qué se modeló el rebote en Python antes de tocar `aim.s`:** pediste
"que la línea rebote contra las bandas como haría la bola una vez
lanzada". Eso es una **simulación geométrica nueva**, no un ajuste de
constante — había que decidir CÓMO reflejar la posición en una pared, y
había más de una manera razonable de hacerlo:

1. Simular paso a paso, como hace la física real (`sys_physics_update_one`),
   comprobando el límite en cada micro-paso y invirtiendo la velocidad al
   cruzarlo. Es fiel al comportamiento real (incluida su imperfección: la
   física del juego "pierde" el sobrante de distancia el frame que rebota,
   no refleja el punto exacto), pero es mucho más código en Z80 (un bucle
   con comprobación de banda en cada iteración) y más lento en tiempo de
   ejecución.
2. Una reflexión analítica: dado que no hay fricción en la vista previa
   (la línea es solo geometría, no física con desgaste), la posición en
   cualquier "distancia recorrida" a lo largo del rayo se puede calcular
   directamente con una fórmula de onda triangular (reflejar sobre un
   intervalo `[lo, hi]` es matemáticamente idéntico a un rayo de billar
   ideal rebotando en una pared recta). Es exacta para cualquier distancia,
   sin bucles, y en Z80 se reduce a una resta y como mucho una suma
   condicional.

Elegí la opción 2. Antes de decidir cuál programar, necesitaba responder dos
preguntas que SÍ son deterministas y por tanto se resuelven en Python, no
adivinando:

- **¿Es correcta la fórmula?** Comparé a mano `reflect(200, 3, 157)` y
  `reflect(-10, 3, 157)` contra el algoritmo que iba a traducir a Z80, y
  luego escribí el macro `ReflectAxis` para que hiciera EXACTAMENTE esas
  mismas operaciones (resta, suma condicional de un período, comparación
  contra el punto medio, resta desde el período). Si hubiera programado el
  Z80 directamente sin este paso, cualquier error de signo o de comparación
  solo se habría visto como "la línea se ve rara en cierta dirección" en el
  emulador — muy difícil de depurar sin saber cuál es el resultado
  correcto de antemano.
- **¿Cabe en los registros del Z80?** El acumulador que lleva la posición
  de cada guion es de 16 bits con signo (rango -32768..32767). Con la
  dirección más extrema de la tabla (`shot_table.s`, componente máximo 64)
  y los nuevos `AIM_STEP_MULT=50`, `AIM_DASH_COUNT=6`, el valor máximo que
  ese acumulador alcanza es 19200 — el script lo calcula
  (`max_raw_magnitude`) y lo compara contra el límite de 32767 ANTES de
  fijar esas constantes. Sin este cálculo, subir el alcance de la línea un
  50% (lo que pediste) podría haber desbordado el acumulador en silencio —
  un bug que en Z80 se manifestaría como la línea "saltando" a una posición
  absurda en ciertas direcciones, y que sería carísimo de rastrear a
  posteriori comparado con una multiplicación y una comparación en Python.
- **¿Necesito de verdad un bucle de módulo general, o basta con una sola
  vuelta?** `check_single_wrap_margin` calcula el desplazamiento máximo real
  en píxeles que un guion puede alcanzar en cada eje y comprueba que nunca
  se sale de un período completo. Esto es lo que me permitió escribir
  `ReflectAxis` con solo DOS ramas condicionales (una suma si es negativo,
  una resta si pasó el punto medio) en vez de un bucle `while` genérico —
  menos código, más rápido, y la garantía de que es correcto queda escrita
  como un `assert` que se vuelve a comprobar automáticamente si algún día
  cambian `AIM_STEP_MULT`, `AIM_DASH_COUNT`, el tamaño de bola o las
  dimensiones del tapete.

El mismo módulo sirvió también para **el tamaño de bola**: antes de fijar
6x6 probé 6x8 y 6x7 reconstruyendo el juego real y midiendo con
`tests/perf_test.py` (que sí corre en el emulador, esto no se puede modelar
en Python porque depende del coste real de las rutinas de dibujo del Z80) —
mezcla de las dos estrategias: lo que es aritmética pura (la geometría de la
línea, el desbordamiento) se resuelve en Python; lo que depende del
**tiempo real** de ejecución del Z80 (cuántas líneas de ráster tarda un
`erase`+`draw`) solo se puede medir corriendo el binario de verdad, así que
para eso no hay atajo: se compiló y se midió tres veces (6x8, 6x7, 6x6) hasta
encontrar el tamaño que cabe en el presupuesto de 50 Hz con margen.

## Resumen de la regla que sigo

| Pregunta | Dónde se resuelve |
|---|---|
| ¿Qué vector (dx,dy) tiene la dirección de 33°? | Python (`gen_shot_table.py`) — es aritmética/trigonometría pura |
| ¿Qué modelo de fricción curva menos la trayectoria? | Python (`friction_model.py`) — comparar dos fórmulas es determinista |
| ¿Cuántos frames tarda una vuelta completa con esta rampa? | Python (`turn_model.py`) — simulación numérica exacta |
| ¿Es correcta la reflexión en la banda? ¿Desborda el acumulador? | Python (`aim_model.py`) — álgebra y límites de rango, verificables sin ambigüedad |
| ¿A cuántos Hz corre el bucle principal con bolas de 6x8 px? | **Solo** midiendo el Z80 real en el emulador (`perf_test.py`) — depende del coste real de instrucciones, no hay forma de derivarlo en Python sin reescribir un simulador de timing del Z80, que no existe en este proyecto |

La línea divisoria es siempre la misma: si la respuesta depende solo de
números y reglas conocidas de antemano, se calcula en Python, una vez, y el
resultado (una tabla, una constante, un umbral, un `assert`) pasa a ser la
referencia fija que el Z80 implementa y que los tests comparan contra el
binario real. Si la respuesta depende de cómo se comporta el hardware/motor
en tiempo real (raster lines, Hz), no hay atajo: hay que compilar y medir —
pero incluso ahí, los scripts Python dejan acotado de antemano qué
constantes probar, para no tener que adivinar a ciegas.
