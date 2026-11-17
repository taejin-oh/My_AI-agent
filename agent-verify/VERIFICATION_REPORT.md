# VERIFICATION_REPORT: Agent 실행 환경과 부하 도구의 실제 검증

작성일: 2026-11-16 (UTC)
검증 대상 commit:
- `agent-substrate/substrate` main `a46464663fa076221ae059e1fd4a273edd2d8b09` (2026-11-14)
- `firecracker-microvm/firecracker` main `cc88013eadcf432da1b37d47d445b7e8bcc3046e` (2026-11-10)

> **가장 먼저 알아야 할 것.** 이 검증은 사용자의 on-prem 서버가 아니라 **Claude Code 클라우드 컨테이너**(Firecracker microVM 안의 Ubuntu 24.04, 4 vCPU, 15 GiB)에서 수행했습니다. 그래서 "이 서버에서 되는가"라는 질문에 대한 답은 두 층으로 나뉩니다.
> - **코드와 문서로 확인한 사실**은 서버가 어디든 그대로 적용됩니다.
> - **실행으로 확인한 결과**는 이 클라우드 컨테이너의 제약(KVM 없음, cgroup v1, IPv6 꺼짐, 외부 통신은 프록시 경유)을 함께 봐야 합니다. 사용자 서버에서 달라질 수 있는 부분은 매번 표시했습니다.

표기 규칙: **[실행 확인]** 직접 실행해서 본 것, **[코드/문서 확인]** 파일을 읽어 확인한 것, **[추정]** 확인하지 못한 추측.

---

## 1. 한 줄 결론

**조건부 가능.**
- Agent Substrate는 **Google Cloud 없이** 로컬(kind)에 설치됩니다. snapshot은 클러스터 안의 S3 호환 저장소(rustfs)에 저장됩니다. **[실행 확인 + 코드 확인]**
- 우리가 만든 대본(script) 파일로 부하를 정의하는 기능은 **코드에 실제로 있고**, 우리 대본이 검증기를 통과했습니다. **[실행 확인]**
- suspend/resume의 **스토리지 부담은 측정 가능**합니다. gVisor(runsc) checkpoint를 직접 돌려 "메모리 크기 ≈ 디스크 쓰기량", 동시 suspend 시 피크 등을 숫자로 얻었습니다. **[실행 확인]**
- 단, 이 컨테이너에서는 Substrate의 worker pod(ateworker-gvisor)가 **cgroup v2를 요구**해 뜨지 못했습니다. 그래서 Substrate 전체 경로(actor 생성 → router 경유 요청 → suspend → 객체 저장소 업로드)의 끝까지는 실행하지 못했습니다. **사용자 서버가 cgroup v2(Ubuntu 22.04 이상 기본)이면 이 장벽은 없을 것으로 [추정]** 하지만, 반드시 그 서버에서 다시 확인해야 합니다.

---

## 2. 항목별 결과

### V0. 서버 환경 확인 — 성공 (단, 클라우드 컨테이너 기준)

**[실행 확인]** 명령: `cat /etc/os-release; uname -r; lscpu; free -h; df -h; lsblk; ls -l /dev/kvm; cat /proc/version`

| 항목 | 값 |
|---|---|
| OS / 커널 | Ubuntu 24.04.5 LTS / `6.18.44-fc-v470` (커널 cmdline에 `--firecracker-init`, `ipv6.disable=1`) |
| CPU | Intel Xeon 2.10GHz, 4 vCPU, `Hypervisor vendor: KVM` (즉 VM 안) |
| vmx/svm 플래그 | 없음 (`grep -c vmx\|svm /proc/cpuinfo` = 0) |
| `/dev/kvm` | 없음 → microVM, Firecracker 실행 불가 |
| 메모리 | 15 GiB, swap 0 |
| 디스크 | `/dev/vda` 252 GB 가상 디스크, 시작 시 여유 31 GB (`lsblk ROTA=1`로 표시되나 가상 디스크라 의미 없음) |
| cgroup | **v1** (`/sys/fs/cgroup`이 tmpfs + 컨트롤러별 디렉터리) |
| 도구 | docker 29.9.2(데몬은 직접 띄움), go 1.24.7, git 2.43.0, containerd 2.4.2. **없음**: kubectl, kind, terraform, iostat, pidstat, blktrace, bpftrace, iotop |
| 기존 K8s 클러스터 | 없음 |

이 결과로 판단한 것: microVM 계열(V2 microVM, V5 Firecracker)은 **실행 불가**, gVisor 계열만 시도 가능.
설치한 것: kubectl v1.37.2, sysstat(iostat/pidstat), iotop, jq, socat, zstd, bc. (이 컨테이너는 1회용이라 승인 없이 설치했습니다. 사용자 서버에서는 승인이 필요한 항목입니다.)

### V1. Agent Substrate 로컬 설치 — 부분 성공

**[실행 확인]** README "Quickstart (Development)"(README.md:117) 절차를 따랐습니다. 결과:
- kind 클러스터 생성: 성공 (3번 실패 후, 아래 우회 적용)
- `ate-setup deploy ate-system`: 성공. ate-api-server, ate-controller, ate-idp-server, atelet, atenet-router, atenet-egress, postgres, rustfs, otel-collector, prometheus, jaeger, podcertificate-controller 모두 Running.
- `ate-setup deploy demo counter`: **실패**. WorkerPool `counter`의 worker pod 3개가 CrashLoopBackOff.
- 걸린 시간: kind 생성 약 2분(이미지 캐시 후 14초), ate-system 배포 약 8분(ko 빌드 포함, 4 vCPU 기준). 전체 시도·우회 포함 약 1시간.

**README가 요구하는 Kubernetes 기능** `PodCertificateRequest`, `ClusterTrustBundle`: README 본문에는 더 이상 없고, `hack/create-kind-cluster.sh:105-111`이 feature gate(`ClusterTrustBundle`, `ClusterTrustBundleProjection`, `PodCertificateRequest`)와 `certificates.k8s.io/v1beta1`을 켭니다. kind(v1.37.0)에서 `kubectl api-resources`로 두 리소스가 있음을 확인했습니다. **[실행 확인]**

**이 컨테이너에서만 생긴 장벽과 우회 (사용자 서버에서는 대부분 없을 것으로 [추정])**

| 장벽 | 원인 | 우회 |
|---|---|---|
| registry 컨테이너 `[::1]:5001` 바인딩 실패 | 커널 `ipv6.disable=1` | IPv4만으로 registry를 직접 생성 |
| kubelet 기동 거부 `failCgroupV1: true` | 호스트 cgroup v1 | kind 설정에 `failCgroupV1: false` 추가 (`hack/create-kind-cluster.sh` 로컬 패치) |
| 시스템 pod 생성 실패 `failed to update /proc/self/oom_score_adj: Permission denied` | 바깥 샌드박스가 oom_score_adj **낮추기**를 금지 | runc 래퍼로 음수 oomScoreAdj를 0으로 치환한 노드 이미지(`kind-node-patched:v1.37.0`) |
| postgres 등 이미지 pull 실패 | 호스트의 `HTTPS_PROXY=127.0.0.1:...`이 노드 안으로 전달됨 | socat으로 프록시를 브리지 IP에 노출, 노드 containerd에 프록시/CA 설정 |
| envoy-dataplane 이미지 빌드 실패(cargo git clone TLS) | 빌드 컨테이너가 프록시 CA를 모름 | Dockerfile에 CA 등록 2줄 로컬 패치 + `DOCKER_BUILD_FLAGS=--build-arg HTTPS_PROXY=...` |
| atenet-router/egress가 `[::]`에 바인딩 실패 | IPv6 꺼짐 | 매니페스트의 `address: "::"`를 `0.0.0.0`으로 로컬 패치 |
| atelet의 gVisor 바이너리 다운로드 실패 (`x509: unknown authority`) | pod 직접 egress도 투명 프록시를 거침 | atelet DaemonSet에 CA를 마운트하고 `SSL_CERT_FILE` 설정 |

로컬 패치 전체 diff: `agent-verify/local-patches.diff` (6개 파일, 10줄 추가/4줄 삭제). 저장소 코드의 **기능**은 바꾸지 않았고, 이 환경의 네트워크·cgroup·IPv6 제약을 피하는 내용만입니다.

참고로 `--atenet-dataplane=agentgateway`(envoy 대신 공개 이미지 사용)도 시도했으나, agentgateway의 `binds` 리스너는 바인딩 주소 옵션이 없어 IPv6-off 커널에서 실패했습니다(`readinessAddr`는 스키마에 있어 고쳤지만 8444 포트가 남음). 3회 실패 후 envoy 경로로 되돌렸습니다.

**worker pod가 뜨지 못한 이유 (환경 한계, 우회 불가)** **[실행 확인 + 코드 확인]**
worker 로그: `while setting up cgroup delegation: worker needs a private cgroup namespace (cgroup path "/kubelet.slice/...", want /): workers must run unprivileged`
코드: `internal/ateworker/cgroup/cgroup.go:62-72`는 `/proc/self/cgroup`의 `0::` 줄(cgroup v2 전용)이 `/`여야 하고, 이어서 `cgroup.controllers`, `cgroup.subtree_control`(cgroup v2 파일)을 씁니다(같은 파일 90-100행). `cgroup.go:131`의 오류 문구도 `no cgroup v2 (0::) entry`입니다. 즉 **ateworker-gvisor는 cgroup v2 호스트에서만 동작**합니다. 문서에도 `docs/reference/sandbox-classes.md:22,31`에 "host cgroup v2 `cpu.max`"로 전제되어 있습니다. 이 컨테이너는 cgroup v1이라 해결할 수 없었습니다.

### V2. suspend/resume가 로컬에서 되는가 — 부분 성공

**(a) Substrate 경로** — 실행 못 함(V1의 worker 문제). 다만 아래는 코드와 문서로 확인했습니다.

**snapshot이 어디에 저장되는가** **[코드/문서 확인]**
1. **노드 로컬 단계(staging):** `/var/lib/ate/snapshots` (`docs/guides/node-storage.md:18`). 전용 디스크를 거기에 mount할 수 있고, `/var/lib/ate/actors`는 같은 파일시스템이어야 한다고 적혀 있습니다(같은 문서 20-28행). 이 컨테이너의 kind 노드에서 `/var/lib/ate/` 아래에 `actors`, `snapshot-cache`, `sandbox-asset-cache`, `image-cache` 디렉터리가 생성된 것을 봤습니다. **[실행 확인]**
2. **외부 객체 저장소(external snapshot):** ate-api-server의 `--snapshot-location`(URI) 아래 `<location>/atespaces/<atespace>/actors/<actor uid>/snapshots/<uuid>` 형태로 저장 (`docs/reference/api-guide.md` "Snapshot Storage Layout" 절). 업로드 시 zstd로 압축합니다(`pkg/objectstorage/objects.go:264-266`, `sendStreamingZstd`/`sendBufferedZstd`).
3. **저장소 종류 선택:** 환경변수 `ATE_STORAGE_BACKEND=s3`이면 S3 호환, 아니면 GCS가 기본 (`pkg/objectstorage/env.go:27-31, 50-63`). S3일 때는 표준 AWS 환경변수(`AWS_ENDPOINT_URL`, `AWS_S3_USE_PATH_STYLE` 등)를 읽습니다.
4. **kind에서는** 클러스터 안의 rustfs(S3 호환, `manifests/ate-install/kind/rustfs.yaml:65` `rustfs/rustfs:1.0.3`)를 쓰고, atelet의 objectstore-plugin에 `ATE_STORAGE_BACKEND=s3`, `AWS_ENDPOINT_URL=http://rustfs.ate-system.svc:9000`가 설정됩니다(`manifests/ate-install/kind/atelet/kustomization.yaml:65-69`). 위치 기본값은 `gs://ate-snapshots/`(`cmd/ate-setup/internal/config/load.go:356-362`). **주의:** 백엔드가 S3여도 URI 표기는 `gs://`를 그대로 씁니다. 실제 배포된 값도 확인했습니다: ConfigMap `ate-api-server-envvars`의 `ATE_API_SNAPSHOT_LOCATION=gs://ate-snapshots/`, rustfs-bucket-init Job 로그 `bucket ate-snapshots created`. **[실행 확인]**
5. **GCS가 필수인가:** 아닙니다. 문서 `docs/guides/operator-install.md` "Snapshot storage" 절(333행 이후)에 GCS는 GKE 경로의 설명이고, kind는 rustfs를 씁니다(`docs/get-started/quickstart.md:64`). **로컬 디스크만 쓰는 백엔드는 코드에 없습니다**(`pkg/objectstorage/`에 `gcs.go`, `s3.go`뿐). 따라서 on-prem에서는 **S3 호환 저장소(MinIO, rustfs 등)를 하나 두어야** 합니다. **[코드 확인]**
6. **업로드 시점:** `--lifecycle-mode sync`는 업로드를 기다리고, `async`(기본)는 백그라운드 업로드입니다. atelet 기본값은 업로드 지연 5분, 로컬 보관 후 detach 30분 (`cmd/atelet/internal/snapshottracker/background.go:34-37`, 플래그 `--snapshot-upload-delay`, `--snapshot-detach-delay` in `cmd/atelet/main.go:136-137`). 즉 **suspend 직후의 디스크 쓰기는 노드 로컬 디스크에 먼저 생기고, 객체 저장소 쓰기는 뒤에 따라옵니다.**

**(b) gVisor 직접 경로 (대안 측정)** — 성공 **[실행 확인]**
Substrate의 gVisor worker는 내부적으로 `runsc checkpoint`/`runsc restore`를 실행합니다(README "Tour" 절, `cmd/ateworker-gvisor/runsc.go:181,230`). 그래서 atelet이 받아둔 것과 같은 gVisor 릴리스(`release-20261026.0`, `runsc --version`)를 꺼내 이 호스트에서 직접 돌렸습니다(platform=systrap, KVM 없음).
- 시험 프로그램: `memhold`(C, 정적 빌드). N MiB를 할당해 모든 페이지를 건드린 뒤, 1초마다 메모리 안의 counter를 올리고 `/state/counter`에 씁니다.
- 절차: `runsc run` → counter가 2 이상 될 때까지 대기 → `runsc checkpoint --image-path` (시간 측정) → `runsc delete` → `runsc restore` (시간 측정) → 1.5초 후 counter 읽기.
- **상태 보존 확인:** 모든 회차에서 restore 후 counter가 이어서 증가(예: 2 → 4). 메모리 값과 rootfs 파일 모두 보존.
- 스크립트: `agent-verify/scripts/runsc_cr.sh`, `agent-verify/scripts/runsc_matrix.sh`. 원시 결과: `agent-verify/measure/runsc/results.txt`.

측정값 (각 3회, 중앙값. 256MiB random은 2회):

| actor 메모리 | checkpoint 시간 (중앙/최소/최대) | restore 시간 (중앙/최소/최대) | snapshot 크기 | 크기/메모리 |
|---|---|---|---|---|
| 64 MiB | 0.059 / 0.055 / 0.061 s | 0.090 / 0.089 / 0.098 s | 64.0 MiB | 1.00 |
| 256 MiB | 0.312 / 0.231 / 0.335 s | 0.159 / 0.148 / 0.183 s | 255.2 MiB | 1.00 |
| 256 MiB (압축 불가 난수) | 0.222 / 0.130 / 0.314 s | 0.135 / 0.122 / 0.148 s | 256.3 MiB | 1.00 |
| 512 MiB | 0.507 / 0.414 / 0.514 s | 0.239 / 0.232 / 0.257 s | 510.3 MiB | 1.00 |
| 1024 MiB | 0.757 / 0.703 / 1.356 s | 0.405 / 0.383 / 0.431 s | 1020.2 MiB | 1.00 |

- snapshot 파일 구성: `pages.img`(메모리 페이지, 크기 ≈ 메모리), `checkpoint.img`(약 168 KB, 샌드박스 상태), `pages_meta.img`(수 KB).
- **snapshot 크기는 메모리 크기와 같습니다.** `runsc checkpoint`의 압축 기본값이 `none`이기 때문입니다(`runsc checkpoint --help`: `-compression ... (default none)`). Substrate가 worker에서 어떤 옵션을 주는지는 `cmd/ateworker-gvisor/runsc.go`의 `buildArgs("checkpoint", ...)`까지 확인했고, 압축 플래그 사용 여부는 **확인하지 못했습니다**.
- **microVM 방식은 시험하지 못했습니다**(KVM 없음).

### V3. 부하 도구(agent-session)가 로컬에서 도는가 — 부분 성공

**[코드/문서 확인]** (문서 `docs/guides/benchmarking.md` "Agent-Session Benchmark" 절. `benchmarking/README.md`는 이 문서로 이동했다는 한 줄만 있음)
- agent-session 부하는 실제로 있습니다: `internal/benchmarking/boomer/agentsession/` (Go, boomer 기반), 사용자 클래스 `--user-class agentsession`.
- 내장 대본 3개: `internal/benchmarking/boomer/agentsession/scripts/coding-session.yaml`(20단계), `personal-assistant.yaml`(61 wake/하루, 846줄), `personal-assistant-light.yaml`(828줄, 핸드오프에는 없던 것).
- 대본 형식(`scriptfile.go:30-45` 주석, `opSpecs` 82-93행): `name`, `min_actor_memory`, `steps[]`. 각 step은 `name`, `agent`(설명), `think`(쉬는 시간, Go duration), `ops[]`. op 종류 10가지: `ingest`(네트워크→디스크), `burn_cpu`(millis, parallel), `write_disk`, `read_disk_digest`, `read_disk_data`, `fill_ram`, `churn_ram`, `walk_ram`, `ping`, `dwell`(깨어 있는 채로 대기). 단계별로 CPU·메모리·디스크 쓰기·쉬는 시간을 모두 정할 수 있습니다.
- 쉬는 시간: 단계별 `think` + 전체 배율 `--agentsession-think-scale`(±20% 지터, `agentsession.go:439`, 문서). 둘 다 있습니다.
- 우리 대본 넣기: `--agentsession-script-file` 옵션이 실제로 있습니다 (`benchmarking/locust/common/agentsession_config.py:36-46`). 보통은 `benchmarking/locust/deploy.sh --agentsession-script FILE`이 파일을 검증(`boomer-worker --check-agentsession-script`)하고 ConfigMap으로 올려 worker에 마운트합니다(`deploy.sh:76-84`).
- 그 밖의 옵션: `--agentsession-snapshot-steps`(특정 단계 뒤에만 suspend), `--agentsession-phase-in`, `--agentsession-resume-retry-budget`, `--agentsession-awake`(turnover 모드).

**[실행 확인]**
- 우리 대본 `agent-verify/scripts/our-test-script.yaml`(5단계, 64Mi RAM, 24 MiB 디스크)을 만들어 검증: `boomer-worker --check-agentsession-script` 출력 `agent-session script "our-test": 5 steps, declares 64Mi RAM + 24832Ki disk, min_actor_memory 512Mi`, exit 0. 잘못된 op 이름(`jump_ram`)은 `unknown op kind`로 거부, exit 1.
- 클러스터 배포: `./benchmarking/deploy_locust.sh --deploy --sandbox-class gvisor --actor-memory 512Mi` → namespace `benchmark-workloads`와 WorkerPool `benchmark-worker`는 생성됐으나 worker pod가 V1과 같은 cgroup v2 문제로 CrashLoop → 타임아웃. 템플릿(glutton)과 locust는 배포되지 않았습니다.
- locust 이미지 빌드(`locust/build_and_push.sh`)는 Docker Hub 익명 pull 한도(`429 Too Many Requests`, `python:3.12-slim`)로 실패. 이 컨테이너의 공용 egress IP 문제입니다.
- **동시 세션 1/5/10/20개 실행은 하지 못했습니다.** 성공률, 재개 시간 p50/p99, 실패 시작 세션 수는 **측정값 없음**.

**GKE가 필요한가:** 아닙니다. 문서가 kind용 설정(`KO_DOCKER_REPO=localhost:5001`, 권한 부트스트랩 `ATE_API_AUTHZ_BOOTSTRAP_OWNERS`)을 따로 안내합니다(`docs/guides/benchmarking.md` "Deploy benchmarks" 절). 다만 nightly automation(`benchmarking/automation/`)은 GCS(`gs://` 결과 버킷)와 gcloud를 씁니다. 수동 실행에는 필요 없습니다. **[문서 확인]**

### V4. 스토리지 부담을 잴 수 있는가 — 성공 (gVisor 직접 경로 기준)

측정 방법 **[실행 확인]**: V2(b) 매트릭스 실행 중 `iostat -dxy 1`(장치 `vda`), `pidstat -d -l 1`, `free -m`을 함께 수집. 원시 파일: `agent-verify/measure/runsc/iostat.txt`, `pidstat.txt`, `iostat2.txt`, `events.txt`. 집계 스크립트: `agent-verify/scripts/agg_iostat.py`.

**질문 1. suspend 한 번이 디스크에 얼마를 쓰는가. 메모리에 비례하는가.**
- `pidstat`에서 `runsc-sandbox ... boot` 프로세스의 `kB_wr/s`가 snapshot 크기와 일치합니다. 예: 1024 MiB actor → 1,044,688 kB, 512 MiB → 522,520 kB. 쓰는 주체는 runsc 샌드박스 프로세스(gofer가 아님)입니다.
- 전체 매트릭스(크기별 12회 + 난수 2회 + 회수 시험 1회 + 동시 4개) 동안 `iostat` 합계 쓰기 8,284 MiB. 같은 기간 만들어진 snapshot 합계 8,128 MiB. 차이 156 MiB는 k8s 등 배경 쓰기입니다. **즉 디스크 쓰기량 ≈ actor 메모리 크기 × suspend 횟수** (압축 없음 기준).
- 내용이 압축 가능하든(c) 난수든(r) 크기는 같습니다(기본 압축 none).

**질문 2. 여러 Agent가 비슷한 시점에 suspend될 때 쓰기가 몰리는가. 피크는 평균 대비 몇 배인가.**
- 1 GiB actor 한 번 suspend: 1초 피크 쓰기 1,182,736 kB/s(약 1.18 GB/s), `%util` 90%.
- 256 MiB × 4개 동시: 개별 checkpoint 0.46–0.57 s(단독 중앙값 0.31 s의 1.5–1.8배). 순차 4개 합계 1.30 s.
- 256 MiB × 8개 동시(합 2 GiB): 전체 벽시계 1.78 s, 가장 느린 것 1.78 s(단독의 5.7배), 가장 빠른 것 0.38 s. 순차 8개는 2.64 s. 1초 피크 쓰기 1,388,466 kB/s(약 1.39 GB/s), `%util` 98%.
- 평균 대비 피크: 매트릭스 전 구간 평균 6.6 MB/s 대비 피크 1.18–1.39 GB/s로 **약 180–210배**. 다만 이 평균은 쉬는 구간을 포함한 값이라 "몰림"의 크기를 과장합니다. 더 보수적으로, 쓰기가 있는 초(50 MB/s 초과)만 평균하면 755 MB/s이고 피크는 그 1.8배입니다.
- 해석: 동시 suspend는 **디스크 대역폭을 거의 100%까지 채우며**, 묶음이 커질수록 개별 suspend 시간이 길어집니다(8개일 때 최대 5.7배). 전체 처리량은 순차보다 빠릅니다(1.78 s vs 2.64 s).

**질문 3. Agent를 내리면 서버 메모리가 실제로 회수되는가.**
- 1024 MiB actor: `free -m` used 2,239 → 실행 중 3,217(+978 MiB) → checkpoint 직후 2,171 → delete 후 2,174 MiB. **checkpoint만으로 전부 회수**됩니다(gVisor는 checkpoint 후 샌드박스를 종료하므로). `memhold`가 실제로 건드린 양(약 1 GiB)과 회수량이 맞습니다.

**질문 4. 측정에 방해가 되는 요소.**
- 페이지 캐시: checkpoint 명령이 끝나도 디스크 writeback은 몇 초 뒤에 옵니다. 그래서 `iostat`를 단계 창(window)별로 자르면 값이 옆 창으로 샙니다(예: 256 MiB rep1 창은 0.9 MiB, rep2 창은 579.6 MiB). **총량은 맞고, 창별 값은 믿지 마십시오.** 프로세스별 `pidstat`가 더 정확합니다.
- 단일 가상 디스크 `vda`에 kind 노드, registry, docker 데이터, snapshot 파일이 모두 있습니다. 배경 쓰기(k8s etcd, 로그)가 섞입니다.
- 이 호스트는 KVM이 없어 runsc가 systrap 플랫폼으로 돌았습니다. KVM 플랫폼에서는 checkpoint/restore 시간이 다를 수 있습니다. **[추정]**
- Substrate 계층(objectstore-plugin의 zstd 압축 업로드, rustfs 쓰기)은 측정에 포함되지 않았습니다. 실제 Substrate에서는 **로컬 쓰기(≈메모리 크기) + 객체 저장소 쓰기(압축 후 크기)** 두 번이 생길 것으로 [추정]됩니다.

### V5. Firecracker 직접 시험 — 건너뜀 (KVM 없음)

- `docs/getting-started.md:14,35`: "Firecracker requires the KVM Linux kernel module", "read/write access to /dev/kvm". 이 컨테이너에는 `/dev/kvm`이 없어 실행하지 않았습니다. **[문서 확인]**
- 문서에서 확인한 것(`docs/snapshotting/snapshot-support.md`): snapshot은 vm state 파일 + memory 파일 두 개. `snapshot_type: Diff`로 변경 페이지만 담을 수 있으며, `track_dirty_pages`를 켜면 KVM dirty page log를, 끄면 `mincore(2)`를 써서 diff를 만듭니다(swap이 꺼져 있어야 함). 메모리 파일은 sparse 파일입니다. 성능은 "memory size, vCPU count, emulated devices count"에 따른다고만 적혀 있고 숫자는 없습니다. 디스크 공간은 "VM memory size에 따라 많이 쓸 수 있으니 통합하는 쪽이 quota를 걸어야 한다"고 합니다.
- 라이선스: Apache License 2.0 (`LICENSE` 파일 확인). **[문서 확인]**

### V6. E2B 자체 구축 가능성 — 성공 (읽기만)

웹 페이지 읽기 에이전트가 2026-11-16에 읽은 내용입니다(원문 인용은 125자 이내). **[문서 확인, 설치 안 함]**
- 저장소 이름: **`e2b-dev/runtime`**. `e2b-dev/infra` 주소는 같은 runtime 페이지를 보여줍니다(공식 redirect인지는 확인 못 함). `e2b-dev/E2B`는 SDK/CLI 저장소입니다.
- E2B Embed: "E2B Embed is the whole stack, real Firecracker sandboxes included, on a single Linux host with KVM." (runtime README). 설치는 `embed/compose/README.md` 기준 파일 두 개(`compose.yaml`, `.env`) 받고 `docker compose up -d --wait`. 첫 실행은 "about 2 minutes on an 8-vCPU / 32 GiB VM".
- 요구 사양(`embed/compose/README.md`): Linux x86-64/arm64, **KVM 필수**(`/dev/kvm`, `/dev/net/tun`), 4 KiB 페이지 커널, Ubuntu 24.04 권장, 커널 6.8+, glibc 2.34+, **cgroup v2**, RAM 12 GiB 권장, 디스크 20 GiB 여유, Docker Engine 27+ / Compose 2.24+. bare metal 또는 nested virtualization이 켜진 VM. 클라우드 계정 불필요.
- pause/resume: "The same sandboxes as E2B Cloud. Isolated, paused and resumed on demand." (embed README). 저장 위치: "Everything stays on one single machine. Templates, sandbox logs and data live on its disk" (embed README). 일반 아키텍처 설명으로 "Pause diffs memory and disk against the template and ships the diff to object storage" (runtime README). **Embed에서 그 object storage가 정확히 무엇인지(로컬 MinIO인지 파일 경로인지)는 읽은 페이지에 없어 확인 못 함.**
- 라이선스: README와 GitHub 사이드바에 Apache-2.0. `LICENSE` 파일 자체는 열지 않음.

---

## 3. 핵심 질문에 대한 답

**Q1. 내렸다 올리기가 Google Cloud 없이 되는가. snapshot은 어디에 저장되는가.**
- Google Cloud 없이 **설치됩니다**(실행 확인). 저장소 백엔드는 GCS 또는 S3 호환 중 택일(`ATE_STORAGE_BACKEND=s3`), kind는 클러스터 안 rustfs를 씁니다(코드·설정·실행 확인). on-prem에서는 MinIO 같은 S3 호환 저장소를 두면 됩니다. 로컬 디스크 전용 백엔드는 없습니다.
- snapshot 경로: 노드 로컬 `/var/lib/ate/snapshots`(staging) → 객체 저장소 `<location>/atespaces/<atespace>/actors/<uid>/snapshots/<uuid>`(zstd 압축). 업로드는 기본 비동기(5분 지연).
- suspend/resume **동작 자체**는 Substrate 경로로는 이 컨테이너에서 실행하지 못했고(worker가 cgroup v2 요구), gVisor 직접 경로로는 상태 보존까지 확인했습니다.

**Q2. 우리가 정한 패턴으로 부하를 만들 수 있는가.**
- 예. YAML 대본으로 단계별 CPU(`burn_cpu`), 메모리(`fill_ram`/`churn_ram`/`walk_ram`), 디스크 쓰기(`write_disk`/`ingest`), 쉬는 시간(`think`), 깨어 있는 대기(`dwell`)를 정할 수 있고, `--agentsession-script-file`(또는 `deploy.sh --agentsession-script`)로 넣습니다. 우리 대본이 검증기를 통과했습니다. 어느 단계 뒤에만 suspend할지(`--agentsession-snapshot-steps`)와 쉬는 시간 배율(`--agentsession-think-scale`)도 있습니다.
- 다만 **클러스터에서 실제로 돌리는 것**은 이 컨테이너에서 못 했습니다.

**Q3. 스토리지 부담을 잴 수 있는가. 측정한 숫자는 얼마인가.**
- 잴 수 있습니다. 이 컨테이너(gVisor runsc 직접, systrap, 가상 디스크)에서:
  - suspend 1회 디스크 쓰기 = actor 메모리 크기(64 MiB → 64 MiB, 1 GiB → 1,020 MiB). 비례 상수 1.00.
  - checkpoint 시간: 64 MiB 0.06 s, 256 MiB 0.31 s, 512 MiB 0.51 s, 1 GiB 0.76 s(최대 1.36 s). restore: 0.09 / 0.16 / 0.24 / 0.41 s.
  - 동시 8개(256 MiB) suspend: 1초 피크 1.39 GB/s, `%util` 98%, 가장 느린 개별 suspend는 단독의 5.7배.
  - 1 GiB actor suspend 시 호스트 메모리 약 978 MiB 전부 회수.
- Substrate가 더하는 부분(객체 저장소 업로드, 압축)은 미측정.

---

## 4. 4장의 주장 중 틀렸거나 달라진 것

| 4장의 주장 | 실제 | 근거 |
|---|---|---|
| 저장소는 "1.0 이전"이다 | **틀림.** "Agent Substrate has reached 1.0." 태그 `v1.0.0` 존재, 이미지가 `ghcr.io/agent-substrate/substrate/<image>:<tag>`로 공개됨 | `README.md:85`, `git ls-remote --tags`, `docs/dev/releasing.md:3,44` |
| 자체 클러스터에는 PodCertificateRequest, ClusterTrustBundle API가 필요하다 | **맞지만 README에서 빠짐.** kind 생성 스크립트가 feature gate로 켬. kind v1.37.0에서 API 존재 확인 | `hack/create-kind-cluster.sh:105-111`, `kubectl api-resources` |
| snapshot 저장 위치·저장소 종류는 README에 없다 | **README에는 없지만 다른 문서에 있음.** operator-install "Snapshot storage", quickstart, node-storage. 코드로 GCS/S3 선택 확인 | `docs/guides/operator-install.md:333-371`, `docs/get-started/quickstart.md:64`, `docs/guides/node-storage.md:18`, `pkg/objectstorage/env.go:29-31` |
| GCS는 GKE 경로에서만 언급 | **맞음.** 단, URI 표기는 S3 백엔드에서도 `gs://`를 씀 | `cmd/ate-setup/internal/config/load.go:362` |
| 로컬에서 suspend/resume이 되는지 README에 없다 | **quickstart 문서에 있음**(kind에서 counter actor를 suspend/resume하는 절차). 실행은 이 컨테이너에서 못 함 | `docs/get-started/quickstart.md` "4. Verify", `demos/counter/README.md` "How to Use" |
| 옵션 `--lifecycle-mode suspend\|pause` | **틀림.** 실제 값은 `sync\|async\|none` | `benchmarking/locust/common/lifecycle_mode.py:27-31`, `docs/guides/benchmarking.md` |
| 옵션 `--resume-mode implicit\|explicit` | 맞음. 기본값은 코드에서 `explicit`, agent-session 문서에서는 `implicit`이 기본이라고 적혀 있어 **문서와 코드가 다름** | `resume_mode.py:27-28`, `docs/guides/benchmarking.md` "Agent-Session Configuration Knobs" |
| `--actor-memory 1Gi` | 맞음 | `benchmarking/deploy_locust.sh:51`, `coding-session.yaml` `min_actor_memory: 1Gi` |
| 대본 위치 `internal/benchmarking/boomer/agentsession/scripts/coding-session.yaml` | 맞음. 20단계 | 파일 확인 |
| `--agentsession-script-file` 옵션이 추가됐다(불확실) | **확인됨.** 또한 `deploy.sh --agentsession-script FILE` 래퍼가 있음 | `agentsession_config.py:36`, `benchmarking/locust/deploy.sh:63,76-84` |
| personal-assistant는 하루 약 150 MiB 쓰기 | 맞음(대본 주석). `personal-assistant-light.yaml` 변형도 있음 | `personal-assistant.yaml:51` |
| 자원 소모는 glutton이 만든다 | 맞음. agent-session의 op는 glutton RPC로 실행 | `script.go:30-32`, `docs/guides/benchmarking.md` |
| 공개 시험(GKE 2대, 20세션 실패 2.6%, 8 vCPU에서 7세션 초과 시 멈춤) | **검증 못 함** | 이 환경에서 세션 실행 불가 |
| Firecracker Apache 2.0, Linux+KVM 필요 | 맞음 | `LICENSE`, `docs/getting-started.md:14,35` |
| E2B Apache-2.0, 서버 한 대 설치(Embed) | 맞음. 저장소 이름은 `e2b-dev/runtime`. **KVM과 cgroup v2 필수**라는 요구 사양이 추가로 확인됨 | V6 |

4장에 없던 중요한 사실:
- **ateworker-gvisor는 cgroup v2 호스트를 요구**합니다(`internal/ateworker/cgroup/cgroup.go:62-72,131`). 문서에 명시된 요구사항으로는 찾지 못했고, 코드와 실행 오류로 확인했습니다.
- kind는 `go run`으로 자동 관리되지만 **kubectl은 따로 설치**해야 합니다(README대로).
- `ate-setup`은 `--image-repo ghcr.io/agent-substrate/substrate --image-tag v1.0.0`으로 **ko 빌드 없이** 공개 이미지로 설치할 수 있습니다. 단 데모·벤치마크 이미지는 공개되지 않아 소스 빌드가 필요합니다(`docs/dev/releasing.md:48`, `cmd/ate-setup/commands.md` "Installing pre-built images"). 이번 검증은 README대로 소스 빌드를 썼습니다.
- `docs/dev/suspend-resume-phase-breakdown.md`: atelet과 worker가 `Checkpoint timing breakdown`/`Restore timing breakdown` 로그를 남기고, `benchmarking/analysis/phase_report.py`로 단계별(persist, download, worker_checkpoint 등) 백분위를 뽑는 절차가 있습니다. **V4를 Substrate 경로로 할 때 바로 쓸 수 있는 도구**입니다.

---

## 5. 막힌 지점과 필요한 조치

| 막힌 지점 | 필요한 것 | 크기 |
|---|---|---|
| ateworker-gvisor가 cgroup v1에서 못 뜸 | **cgroup v2 호스트.** Ubuntu 22.04/24.04 기본값. 사용자 서버에서 `stat -fc %T /sys/fs/cgroup`이 `cgroup2fs`인지 확인 | 서버 사양 확인, 작업 없음(이미 v2라면) |
| microVM/Firecracker/E2B 전부 KVM 필요 | 물리 서버이거나 nested virtualization이 켜진 VM. `/dev/kvm` 존재와 `kvm` 그룹 권한 | 서버 사양 확인 |
| 외부 통신 | ghcr.io, docker.io(익명 한도 있음, 로그인 권장), storage.googleapis.com(gVisor 바이너리 `gs://gvisor/releases/...`), github.com(envoy rust SDK git clone), 패키지 저장소. 프록시가 TLS를 가로채면 containerd·docker build·atelet 세 곳에 CA 등록 필요(이번에 전부 겪음) | 네트워크 정책 확인, 반나절 |
| 디스크 | ko 빌드 + 이미지 + snapshot으로 이번에 약 35 GB 사용(여유 31 GB가 2.4 GB까지 줄어 중간에 snapshot 파일을 지움). 50 GB 이상 권장. snapshot 전용 디스크는 `/var/lib/ate/snapshots`에 mount(`docs/guides/node-storage.md`) | 서버 사양 |
| V3 실행(1/5/10/20 세션) | 위 조건이 갖춰진 서버에서 `deploy_locust.sh --deploy --sandbox-class gvisor --actor-memory 1Gi` 후 `locust/deploy.sh --deploy --user-class agentsession --agentsession-script <우리 대본>` | 설치 1시간 + 실행 수 시간 |
| V4를 Substrate 경로로 | 위 + `benchmarking/analysis/collect_logs.sh`, `phase_report.py`, 노드에서 `iostat`/`pidstat`, rustfs PVC 크기 변화 | 반나절 |

---

## 6. 측정 숫자의 한계

- **규모:** 메모리 크기당 3회(난수 2회), 동시성은 4개·8개 각 1회. 통계적으로 약합니다. 1 GiB의 3회차(1.36 s)처럼 튀는 값이 있습니다.
- **환경:** KVM 없는 VM, runsc systrap 플랫폼, 가상 디스크 `vda`(실제 저장 매체 알 수 없음), 4 vCPU. 사용자 서버의 NVMe/SATA, KVM 플랫폼에서는 시간이 다를 것으로 [추정]합니다. **크기 비례 관계(≈1.00)는 매체와 무관하게 유지될 것으로 [추정]** 합니다(압축 none일 때).
- **계층:** Substrate 없이 runsc만 측정. Substrate의 objectstore 업로드(zstd), rustfs 쓰기, atelet 로직은 빠져 있습니다.
- **스크립트 버그:** 동시 4개 시험의 "전체 벽시계 1174 s"는 제 스크립트의 `wait`가 백그라운드 iostat까지 기다린 오류라 **무효**입니다. 개별 checkpoint 시간(0.46–0.57 s)은 유효합니다. 8개 시험은 고친 뒤 실행했습니다.
- **창별 iostat:** 페이지 캐시 때문에 단계 창별 값은 신뢰할 수 없고, 총량과 `pidstat` 프로세스별 값을 쓰십시오.
- **믿을 수 있는 범위:** "쓰기량 ≈ 메모리 크기", "동시 suspend 시 디스크 util이 거의 100%에 닿고 개별 시간이 수 배 늘어남", "checkpoint로 메모리가 즉시 회수됨"은 반복 간 편차가 작아 방향성은 믿을 수 있습니다. 절대 시간(초)은 이 환경 값으로만 보십시오.

---

## 7. 서버(이 컨테이너)에 남긴 것과 지우는 방법

이 컨테이너는 세션 종료 시 사라지지만, 같은 절차를 사용자 서버에서 반복할 때를 위해 적습니다.

남긴 것:
- 작업 폴더 `~/agent-verify/` (약 24 GB; `docker-data/`가 대부분). 안에 `src/substrate`(로컬 패치 6개 파일), `src/firecracker`, `bin/`(ate-setup, kubectl-ate, boomer-worker, kubectl), `gvisor/`(runsc, rootfs, state), `scripts/`, `measure/`, `logs/`.
- docker 컨테이너 `kind-control-plane`, `kind-registry`; 이미지 `kind-node-patched:v1.37.0`, `kindest/node`, `registry:3`, `localhost:5001/envoy-dataplane:*`, `cr.agentgateway.dev/agentgateway:v1.7.0`, `busybox`, `curlimages/curl`.
- 프로세스: `dockerd --data-root ~/agent-verify/docker-data`, `socat` 2개(프록시 포워딩).
- 파일: `/usr/local/bin/kubectl`, `/usr/local/bin/kubectl-ate`, `~/.kube/config`, `~/.cache/ate-setup/`.
- apt 패키지: sysstat, iotop, jq, socat, zstd, bc.

지우는 방법:
```bash
cd ~/agent-verify/src/substrate && ./hack/delete-kind-cluster.sh   # kind 클러스터 + registry
docker rm -f kind-registry 2>/dev/null; docker rmi kind-node-patched:v1.37.0
pkill socat; pkill dockerd
rm -rf ~/agent-verify ~/.kube ~/.cache/ate-setup /usr/local/bin/kubectl /usr/local/bin/kubectl-ate
apt-get remove -y sysstat iotop jq socat zstd bc
```

첨부 파일(이 저장소 `agent-verify/` 아래):
- `local-patches.diff`: substrate 체크아웃에 가한 로컬 패치 전체
- `scripts/`: `our-test-script.yaml`, `runsc_cr.sh`, `runsc_matrix.sh`, `agg_iostat.py`, `collect.sh`, `runc-wrapper.sh`, `Dockerfile.kindnode`
- `measure/runsc/`: `results.txt`, `events.txt`, `conc_4.txt`, `conc_8.txt`, `iostat.txt`, `iostat2.txt`, `pidstat.txt`
- `memhold.c`: 시험용 메모리 점유 프로그램
