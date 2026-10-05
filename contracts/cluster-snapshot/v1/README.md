# Cluster snapshot contract v1

Bundle canonico, offline e versionato dello **stato di un cluster Kubernetes** che `closeyourit-kube`
(Go) invia a `closeyourit-rails` con `POST /api/v1/clusters/snapshots`. `schema.json` usa JSON Schema
Draft 2020-12; `fixtures/valid` deve validare contro il proprio `$defs`, `fixtures/invalid` descrive
payload che il producer non deve mai emettere.

Decisione: [`decisions/2026-10-02-cluster-kubernetes-osservatore.md`](../../../decisions/2026-10-02-cluster-kubernetes-osservatore.md)
(ticket `CYAG-22`). Producer: `closeyourit-kube/internal/snapshot` + `internal/push`. Consumer:
`closeyourit-rails`, dominio `Clusters::` (Piano 2).

## Trasporto

| Aspetto | Valore |
|---|---|
| Metodo e path | `POST {endpoint}/api/v1/clusters/snapshots` |
| Header | `Content-Type: application/json`, `Content-Encoding: gzip`, `Authorization: Bearer cyi_k_…`, `User-Agent: closeyourit-kube/<versione>` |
| Body | JSON dell'oggetto `snapshot`, sempre gzip |
| Cadenza | uno snapshot per tick, default 60 s, minimo 15 s (`CYI_INTERVAL`) |
| Retry client | 2 tentativi in più nello stesso tick, con attesa crescente e jitter, solo per esiti `retry` |
| Tetto dimensione | 1 MiB compresso |
| Risposta | `202 {"data":{"accepted":true,"cluster_id":<uuid>}}` (`$defs/snapshot_response`) |
| Errori | `{"error":{"code":"R###-CLUSTER-###","message":…}}` (`$defs/error_envelope`) |

## Credenziale

Un codice `cyi_k_…` **per cluster**, creato da «Aggiungi cluster» e mostrato una volta. Il codice è
l'identità del cluster: nessun fingerprint. Un codice sconosciuto risponde `401 R401-CLUSTER-001`, uno
revocato `401 R401-CLUSTER-002`. Un bearer di progetto `cyi_` o di flotta `cyi_s_` non vale qui.

## Semantica

- **Stato completo a ogni invio**, mai differenze: uno snapshot perso non lascia lo stato sbagliato.
- **`snapshot_id`** (UUID) rende l'invio idempotente: lo stesso id ricevuto due volte risponde `202`
  e non cambia nulla.
- **Tetti**: 500 nodi, 3.000 workload, 3.000 namespace, 200 eventi, messaggio evento 512 caratteri.
  Oltre, l'osservatore taglia (le liste sono già ordinate: nodi e workload per nome, eventi dal più
  recente) e mette `truncated: true`.
- **Eventi**: solo `type=Warning`, visti dopo l'ultimo snapshot che ha lasciato l'osservatore per
  sempre (accettato o scartato). Uno snapshot da ritentare li ripropone.
- **Metriche**: senza `metrics.k8s.io` `cluster.metrics_available` è `false` e
  `cpu_usage_millicores`/`memory_usage_bytes` sono `null`. `null` significa «non misurato», mai zero.
- **`being_removed`**: il nodo ha il taint `ToBeDeletedByClusterAutoscaler`; il server non deve
  avvisare «macchina non pronta» per lui.
- **`last_reason`**: il motivo di attesa più utile tra i pod dell'app (`CrashLoopBackOff`,
  `ImagePullBackOff`, `ErrImagePull`, `CreateContainerConfigError`, `CreateContainerError`,
  `InvalidImageName`, `Unschedulable`), altrimenti l'ultima terminazione (`OOMKilled`, `Error`…),
  altrimenti `null`.
- **`restarts`**: somma dei `restartCount` dei pod attuali dell'app. È un contatore che può scendere
  quando i pod vengono ricreati: il server calcola le ripartenze recenti dalle differenze positive.

## Compatibilità

Lo schema è **stretto** (`additionalProperties: false`): è l'obbligo del producer, che emette solo
chiavi dello schema. Il server **ignora** le chiavi che non conosce e non valida a runtime con questo
schema, così un osservatore più nuovo non viene rifiutato da un server più vecchio. Un campo nuovo
entra prima qui, poi nei due consumer con un nuovo `LOCK.json`.

## Esiti HTTP e disposizione dell'osservatore (`fixtures/http/cases.json`)

| Esito | Codice | Disposizione | Cosa fa l'osservatore |
|---|---|---|---|
| `202` | — | `ok` | avanza la finestra degli eventi |
| `401` | `R401-CLUSTER-001`, `R401-CLUSTER-002` | `unauthorized` | lo scrive nei log e aspetta 15 minuti |
| `413` | `R413-CLUSTER-001` | `drop` | scarta quello snapshot e avanza |
| `422` | `R422-CLUSTER-001` | `drop` | scarta quello snapshot e avanza |
| `429`, `5xx`, errore di rete | — | `retry` | ritenta nel tick, poi al tick successivo |

## File

| File | Contenuto |
|---|---|
| `schema.json` | `$defs`: `snapshot`, `cluster`, `node`, `namespace`, `workload`, `event`, `snapshot_response`, `error_envelope` |
| `manifest.json` | fixture → `$defs` e validità attesa |
| `fixtures/valid/` | `minimal`, `complete`, `no_metrics`, `limits` (esattamente sui tetti), risposte |
| `fixtures/invalid/` | una violazione per file, compresi i tetti superati di uno |
| `fixtures/http/cases.json` | esiti HTTP e disposizione attesa |
| `SHA256SUMS` | impronte di tutti i file del bundle |

Le fixture grandi si rigenerano con `scripts/gen_cluster_snapshot_fixtures.py`; il bundle si verifica
con `scripts/verify_cluster_snapshot_contract.py`.
