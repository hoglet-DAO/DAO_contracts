# DAO Factory v3 - Contract Architecture

Este directorio contiene los contratos inteligentes (`smart contracts`) escritos en **Move** que definen la lógica y reglas de la fábrica de DAOs bajo el modelo **ve(3,3)** y gobernanza activa.

A continuación se presenta la correspondencia directa entre los conceptos de la interfaz (las ilustraciones de "How it Works") y la implementación real a nivel de código en los contratos:

## 1. El Reloj Cósmico y Épocas compartidas (Capítulo 1 - The Clock)
**Concepto:** Un reloj universal donde todo se sincroniza (7 villas orbitando en perfecta sincronía).
**Contratos (`jubilee.move` / `pilgrim.move` / `zeal.move`):**
Todo el protocolo funciona bajo un estricto **sistema de Épocas (Epochs)** de 7 días (como las 7 villas). La inflación de nuevos tokens (`advance_epoch` en `jubilee.move`) y el poder de voto se resetean y calculan en base a este reloj central que dicta el ritmo absoluto de la economía.

## 2. Bloqueos y Decaimiento Lineal (Capítulo 2 - Locks & Power / Decay)
**Concepto:** Una escalera que desciende suavemente, simbolizando el decaimiento lineal del poder de voto a través del tiempo.
**Contrato (`legacy.move`):**
Los usuarios bloquean sus tokens para obtener un NFT de gobernanza (veToken). El poder de voto no es estático; se calcula a través de la función `get_voting_power_at` que implementa un decaimiento (decay) basado en cuántas épocas le quedan a tu candado. A medida que pasa el tiempo, el poder de voto desciende suavemente.

## 3. Ventana de Votación (Capítulo 3 - Voting Window)
**Concepto:** El usuario votando en un podio con gráficos de barras (eligiendo opciones).
**Contrato (`zeal.move`):**
A través de la función `vote()`, los usuarios con poder de voto asignan "pesos" a diferentes Gauges (Destinos de inflación). Cada época, el poder de los usuarios dictamina exactamente qué porcentaje de la inflación se dirige a cada pozo de liquidez.

## 4. El Cierre del Miércoles (Capítulo 3 - Miércoles Lockout)
**Concepto:** Dormir junto a un candado seguro; descanso previo al cierre.
**Contrato (`zeal.move`):**
Existe una regla estricta anti-manipulación conocida como "Voter Lockout". El código verifica: `assert!(pilgrim::seconds_until_next_epoch() > 86400, error::invalid_state(E_VOTING_CLOSED));`. Esto bloquea cualquier votación o soborno en las últimas 24 horas de la época (el miércoles, si la época cierra el jueves), evitando "sniping" de última hora.

## 5. El Día de Cobro (Capítulo 3 - Jueves Claim)
**Concepto:** Monedas lloviendo desde una piñata; celebración del día de pago.
**Contratos (`jubilee.move` / `harvest.move`):**
Una vez que el reloj avanza de época, los usuarios pueden reclamar su porción de la inflación (Rebase) y sus recompensas de protocolos (`claim_rewards`). La época transiciona y se distribuye el capital a los Gauges y a los votantes.

## 6. El Robot Keeper y la Bóveda (Capítulo 4 - Keeper & Vault)
**Concepto:** Un robot autónomo jalando un vagón de monedas y una Bóveda (Vault) sagrada garantizando los fondos.
**Contratos (`zeal.move`):**
El sistema usa una arquitectura **"Pull"**. Cuando termina una época, la inflación no se empuja automáticamente a todos (lo que sería costoso en gas). En su lugar, va a un Vault principal, y cualquier entidad externa (un Keeper, un Bot o un usuario) puede llamar a `claim_gauge_emission()` para mover las monedas del Vault hacia los Gauges ganadores, como un robot de entregas sin permiso.

## 7. El Timelock (Capítulo 5 - Timelock)
**Concepto:** Un reloj de arena con arena congelada; tensión controlada y seguridad.
**Contratos (`charter.move` / `herald.move`):**
Cualquier propuesta aprobada por la gobernanza no se ejecuta instantáneamente. Existe un `timelock_delay` paramétrico (configurado en la "Carta Magna" de la DAO en `charter.move`) que obliga a la propuesta ganadora a esperar congelada un tiempo antes de que su código afecte al protocolo, permitiendo a los usuarios reaccionar.

## 8. El Guardián (Emergencias)
**Contrato (`sentinel.move`):**
Además de la gobernanza normal, se incorpora un "Interruptor de Circuito" (Circuit Breaker) que permite a un "Guardián" de confianza pausar funciones del sistema (`is_paused`) por un máximo de 2 épocas. Crucialmente, el código nunca permite pausar la función `withdraw` (retirar fondos).
