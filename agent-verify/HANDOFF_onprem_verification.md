# 핸드오프 2: on-prem 서버에서 Agent 실행 환경 구축과 스토리지 부담 측정

이 문서는 Claude Code에게 넘기는 작업 지시서입니다. 1차 검증(2026-11-16, `VERIFICATION_REPORT.md`)은 클라우드 컨테이너에서 했기 때문에, Agent Substrate의 컨트롤 플레인 설치와 gVisor checkpoint 측정까지만 됐고, **worker pod 실행 이후(actor 생성, 부하 실행, 객체 저장소 업로드 측정)는 하지 못했습니다.** 이번 작업의 목적은 **사용자 서버에서 그 나머지를 끝내는 것**입니다.

1차 검증에서 확인된 사실은 4장에 "확인됨"으로 표시했습니다. 그 부분은 다시 조사할 필요가 없습니다. 다만 저장소가 바뀌었을 수 있으니, 4장에 적힌 파일 경로와 줄 번호는 실행 전에 한 번 다시 열어 보십시오.

## 1. 배경

- **과제:** Enterprise Agent 환경에서 쉬는 Agent를 메모리에서 저장장치로 내렸다가(suspend) 다시 올릴(resume) 때 스토리지에 생기는 부담을 직접 구축한 환경에서 재는 것.
- **대상 환경:** 사용자의 on-prem 서버 한 대. 외부 클라우드 자원은 쓰지 않습니다.
- **쓸 도구:** Agent Substrate(`agent-substrate/substrate`, Apache-2.0)와 그 안의 agent-session 부하 도구. 보조로 gVisor `runsc` 직접 실행.
- **이번에 답해야 할 질문:**
  1. 이 서버에서 Substrate의 worker가 뜨고, actor를 만들고, suspend/resume이 끝까지 되는가.
  2. 우리 대본으로 동시 세션 1·5·10·20개를 돌릴 수 있는가. 성공률과 재개 시간은 얼마인가.
  3. suspend 한 번이 **노드 로컬 디스크**와 **객체 저장소**에 각각 얼마를 쓰는가. 여러 actor가 동시에 내려갈 때 피크는 얼마인가.

## 2. 작업 원칙

1. **이 문서의 내용을 사실로 믿지 마십시오.** 4장은 1차 검증 결과이며, 저장소가 바뀌었을 수 있습니다. 다르면 다르다고 보고하십시오.
2. **추측하지 마십시오.** 실행해서 확인한 것, 코드나 문서를 읽어 확인한 것, 확인하지 못한 것을 반드시 구분하십시오.
3. **막히면 우회하지 말고 기록하십시오.** 같은 문제로 세 번 실패하면 기록하고 다음으로 넘어가십시오. 1차 검증에서는 환경 우회에만 약 1시간을 썼습니다.
4. **서버를 바꾸는 작업은 먼저 물어보십시오.** sudo, 패키지 설치, sysctl 변경, 기존 Kubernetes/컨테이너 변경, 디스크 수십 GB 이상 사용. **1차 검증과 달리 이번 서버는 1회용이 아닙니다.**
5. **외부 클라우드 자원을 만들지 마십시오.** `gcloud`, `gs://` 결과 버킷, GKE 설치 경로는 쓰지 마십시오. `benchmarking/automation/`은 GCS를 쓰므로 쓰지 마십시오.
6. **내려받은 저장소의 스크립트는 실행 전에 읽으십시오.** 특히 `hack/create-kind-cluster.sh`는 같은 이름의 kind 클러스터를 **지우고** 다시 만듭니다.
7. **작업 폴더는 `~/agent-verify/` 하나만 쓰십시오.** docker 데이터는 기본 경로를 그대로 두되, 이번 작업으로 늘어난 이미지·컨테이너 목록을 끝에 적으십시오.
8. **1차 검증의 로컬 패치(`local-patches.diff`)를 먼저 적용하지 마십시오.** 그 패치는 클라우드 컨테이너의 제약(cgroup v1, IPv6 꺼짐, 프록시 CA)을 피하는 용도였습니다. 사용자 서버에서는 필요 없을 가능성이 높고, 필요하면 그때 같은 증상이 났는지 확인한 뒤 적용하십시오.

## 3. 검증 항목

각 항목의 결과는 **성공 / 부분 성공 / 실패 / 건너뜀** 중 하나로 적으십시오.

### W0. 서버 사전 조건 확인 (읽기만, 변경 없음)

1차 검증에서 막힌 원인이 전부 서버 사양이었으므로, 아래를 **가장 먼저** 확인해 사용자에게 알리십시오. 하나라도 빠지면 이후 항목 중 무엇이 불가능한지 같이 적으십시오.

| 확인 | 명령 | 필요한 값 | 없으면 막히는 것 |
|---|---|---|---|
| cgroup 버전 | `stat -fc %T /sys/fs/cgroup` | `cgroup2fs` | **ateworker-gvisor가 못 뜸** (W1 이후 전부). 근거: `internal/ateworker/cgroup/cgroup.go:62-72,131` |
| KVM | `ls -l /dev/kvm; grep -c -E 'vmx\|svm' /proc/cpuinfo` | 장치 있음, 플래그 1 이상 | microVM 클래스, Firecracker(W5), E2B(W6) |
| IPv6 | `cat /proc/sys/net/ipv6/conf/all/disable_ipv6` | `0` | kind registry의 `[::1]` 바인딩, envoy의 `::` 리스너 |
| 커널 neighbor table | `sysctl net.ipv4.neigh.default.gc_thresh3` | 1024면 경고만. 1000개 이상 샌드박스에서만 문제 | 대규모 실행 |
| docker | `docker info` | 데몬 동작, cgroup v2, 가능하면 `Cgroup Driver: systemd` | 전부 |
| go, kubectl, git | `go version; kubectl version --client; git --version` | go 1.24 이상(저장소 `go.mod` 확인), kubectl은 **따로 설치** 필요 | 설치 |
| 외부 통신 | `curl -sI https://ghcr.io https://registry-1.docker.io/v2/ https://storage.googleapis.com https://github.com` | 전부 응답 | ko 빌드, 이미지 pull, gVisor 바이너리(`gs://gvisor/releases/...`) 다운로드, envoy rust SDK git clone |
| 프록시/TLS 가로채기 | `env \| grep -i proxy`; 위 curl이 인증서 오류를 내는지 | 없는 것이 좋음 | 있으면 containerd, docker build, atelet pod 세 곳에 CA 등록 필요 (1차 검증에서 전부 겪음) |
| Docker Hub 한도 | `docker pull python:3.12-slim` | 429가 나면 `docker login` 필요 | locust 이미지 빌드 |
| 디스크 | `df -h /var/lib/docker /` | **여유 60 GB 이상** 권장 | 1차 검증은 ko 빌드·이미지·snapshot으로 약 35 GB를 썼고 여유 2.4 GB까지 떨어짐 |
| 디스크 종류 | `lsblk -d -o NAME,ROTA,MODEL`; `cat /sys/block/*/queue/rotational` | NVMe 권장 | 측정값 해석 |
| 메모리/CPU | `free -h; nproc` | 16 GiB·8 vCPU 이상 권장 | 동시 세션 수 |
| 측정 도구 | `which iostat pidstat iotop` | sysstat | W4 (없으면 설치 승인 요청) |

### W1. Agent Substrate 설치 (README 절차 그대로)

1차 검증에서 성공한 순서입니다. 저장소 README "Quickstart (Development)"를 다시 읽고 바뀐 것이 있으면 README를 따르십시오.

```bash
mkdir -p ~/agent-verify/src && cd ~/agent-verify/src
git clone https://github.com/agent-substrate/substrate.git && cd substrate
git log -1 --format='%H %ad'            # 사용한 commit 기록

hack/create-kind-cluster.sh              # kind는 go run으로 자동 관리됨 (hack/kind.sh)
export ATE_INSTALL_KIND=true             # ate-setup을 쓰는 모든 셸에서

go build -o ~/agent-verify/bin/ate-setup ./cmd/ate-setup     # 1차 검증: 50초
~/agent-verify/bin/ate-setup deploy ate-system \
  --credential-provider='{"name":"k8s.io"}' \
  --ingress-allowed-spiffe-ids=spiffe://cluster.local/ns/ate-system/sa/atenet-client \
  --rollout-timeout=300s
```

- **`--sandbox-classes=gvisor`를 붙이면** microVM 자산(kata-static, cloud-hypervisor) 다운로드를 건너뜁니다. KVM이 있으면 붙이지 말고 기본값(`gvisor,microvm`)으로 두십시오.
- 벤치마크(W3)를 돌릴 것이므로 **처음부터** 아래 두 환경변수를 넣어 설치하십시오. 나중에 다시 설치하면 ko 빌드가 반복됩니다. 근거: `docs/guides/benchmarking.md` "Deploy benchmarks" 절.
  ```bash
  ATE_API_AUTHZ_BOOTSTRAP_OWNERS=system:serviceaccount:ate-system:ate-client,spiffe://cluster.local/ns/benchmarking/sa/default \
  ATE_INGRESS_ALLOWED_SPIFFE_IDS=spiffe://cluster.local/ns/benchmarking/sa/default,spiffe://cluster.local/ns/ate-system/sa/atenet-client \
  ~/agent-verify/bin/ate-setup deploy ate-system --credential-provider='{"name":"k8s.io"}' --rollout-timeout=300s
  ```
  (`--ingress-allowed-spiffe-ids`와 `ATE_INGRESS_ALLOWED_SPIFFE_IDS`는 같은 설정입니다. 두 SPIFFE ID를 쉼표로 모두 넣는 형식이 맞는지 `cmd/ate-setup/commands.md`에서 확인하십시오.)
- 실패하면 `~/.cache/ate-setup/failed/<timestamp>.yaml`이 남고, `ate-setup deploy ate-system --config <그 파일>`로 같은 설정으로 재시도할 수 있습니다. 1차 검증에서 유용했습니다.
- 기록할 것: commit, 걸린 시간(단계별 `[step]:` 로그), `kubectl get pods -A` 결과, 막힌 지점.

**확인할 것:**
- `kubectl get pods -n ate-system`에서 ate-api-server(2/2), atelet(2/2), atenet-router(2/2), atenet-egress(3/3), postgres(2/2), rustfs(1/1)가 Running인가.
- `kubectl logs -n ate-system -l app=atelet -c atelet | grep -i "sandbox asset"`에서 gVisor 자산 다운로드가 성공하는가. 1차 검증의 실패 문구: `tls: failed to verify certificate`.

### W2. counter demo로 suspend/resume 끝까지 — 가장 중요

```bash
~/agent-verify/bin/ate-setup deploy demo counter --rollout-timeout=600s
go install ./cmd/kubectl-ate     # 또는 go build -o ~/agent-verify/bin/kubectl-ate ./cmd/kubectl-ate 후 PATH에 추가
kubectl ate get actor-templates -a ate-demo-counter      # GOLDEN TAG 열이 UUID가 될 때까지 대기
kubectl ate create actor my-counter-1 -a ate-demo-counter --template counter
kubectl ate proxy actor my-counter-1 -a ate-demo-counter   # 별도 터미널, 포트 8000
curl -X POST http://localhost:8000      # preserved memory count: 1 | ...
kubectl ate get actor my-counter-1 -a ate-demo-counter     # ACTOR_STATE_RUNNING, WORKER POD
kubectl ate suspend actor my-counter-1 -a ate-demo-counter --mode=sync   # 업로드까지 기다림
kubectl ate get actor my-counter-1 -a ate-demo-counter     # SUSPENDED, WORKER POD <none>
curl -X POST http://localhost:8000      # 세 counter가 모두 2가 되어야 함
```

**1차 검증에서 worker pod가 죽은 지점**: `kubectl logs -n ate-demo-counter -l ate.dev/worker-pool=counter`에 `worker needs a private cgroup namespace`가 나오면 **cgroup v2가 아닌 것**입니다. 이 경우 더 진행하지 말고 사용자에게 보고하십시오.

**반드시 밝힐 것(저장 위치, 실제 파일로):**
- 노드 로컬: kind 노드 안 `/var/lib/ate/snapshots/`와 `/var/lib/ate/actors/` 아래 어떤 파일이 생기는가. `docker exec kind-control-plane ls -laR /var/lib/ate/snapshots | head -50`, `du -sh`. 파일 이름과 크기를 적으십시오. (1차 검증: 디렉터리 구조만 확인, 파일은 못 봄)
- 객체 저장소: rustfs 버킷 `ate-snapshots` 안의 객체 목록과 크기. rustfs는 S3 호환이므로 포트포워딩 후 aws cli로 확인할 수 있습니다.
  ```bash
  kubectl port-forward -n ate-system svc/rustfs 9000:9000 &
  AWS_ACCESS_KEY_ID=rustfsadmin AWS_SECRET_ACCESS_KEY=rustfsadmin AWS_REGION=us-east-1 \
    aws --endpoint-url http://localhost:9000 s3 ls --recursive --human-readable s3://ate-snapshots/
  ```
  (자격 증명은 `manifests/ate-install/kind/rustfs.yaml`에 평문으로 있음. 경로 형식은 `docs/reference/api-guide.md` "Snapshot Storage Layout": `atespaces/<atespace>/actors/<uid>/snapshots/<uuid>/...`)
- **로컬 파일 크기(압축 전)와 객체 크기(zstd 압축 후)의 비율**을 적으십시오. 이것이 "suspend 한 번의 쓰기량 = 로컬 + 객체 저장소"의 핵심 숫자입니다.
- `kubectl ate get actor my-counter-1 -a ate-demo-counter -o yaml`의 `status.snapshots[]`에서 `durableSnapshot.state`(PENDING→COMPLETED)와 `object.snapshotUri`를 적으십시오.

**잴 것:** `--mode=sync` suspend 시간, resume(curl 첫 응답) 시간, 로컬 snapshot 크기, 객체 크기, actor 메모리 한도(`counter` 템플릿의 `resources.limits.memoryBytes`)와의 관계. 각 3회.

**단계별 시간 분해:** `docs/dev/suspend-resume-phase-breakdown.md` 절차대로 `benchmarking/analysis/collect_logs.sh --dest ~/agent-verify/measure/phase --since 30m` 후 `python3 benchmarking/analysis/phase_report.py ...`로 `persist`(로컬 쓰기), `upload`, `download`, `worker_checkpoint`, `worker_restore` 백분위를 뽑으십시오. 이 도구는 1차 검증에서 문서만 확인했습니다.

**microVM:** W0에서 KVM이 확인되면 `demos/counter/README.md` "Running on microVM" 절을 따라 같은 측정을 한 번 더 하십시오.

### W3. agent-session 부하를 우리 대본으로 실행

```bash
export KO_DOCKER_REPO=localhost:5001
./benchmarking/deploy_locust.sh --deploy --sandbox-class gvisor --actor-memory 1Gi --worker-count 1
# 위 스크립트가 locust 이미지를 docker build + push 함. Docker Hub 429가 나면 docker login 후 재시도
./benchmarking/locust/deploy.sh --deploy --user-class agentsession \
  --agentsession-script ~/agent-verify/scripts/our-test-script.yaml
kubectl port-forward svc/locust -n benchmarking 8089:8089
```

- 우리 대본: 1차 검증의 `agent-verify/scripts/our-test-script.yaml`(5단계, 64Mi RAM, 24 MiB 디스크, `min_actor_memory: 512Mi`)을 출발점으로 쓰십시오. 검증기는 `go run ./cmd/benchmarking/boomer-worker --check-agentsession-script FILE`입니다.
- 대본을 바꿀 때 규칙(`internal/benchmarking/boomer/agentsession/scriptfile.go`): op는 10종(`ingest`, `burn_cpu`, `write_disk`, `read_disk_digest`, `read_disk_data`, `fill_ram`, `churn_ram`, `walk_ram`, `ping`, `dwell`), 크기는 K8s quantity(`16Mi`), `think`는 Go duration(`2s`), 알 수 없는 필드는 오류, `min_actor_memory`는 선언한 RAM+디스크 이상이어야 함.
- 쉬는 시간 조정: 단계별 `think`, 전체 배율 `--agentsession-think-scale`(±20% 지터), 특정 단계 뒤에만 suspend하려면 `--agentsession-snapshot-steps 2,4`.
- 옵션 값은 **`--lifecycle-mode sync|async|none`**, `--resume-mode explicit|implicit`입니다(1차 핸드오프의 `suspend|pause`는 틀린 값). 스토리지 측정에는 **`sync`**가 명확합니다(업로드까지 포함해 재므로). 기본값 `async`로도 한 번 비교하십시오.
- Locust 웹 UI(`http://localhost:8089`)에서 사용자 수 1 → 5 → 10 → 20, spawn rate 1, 각 10분. 헤드리스 `runner.py`는 "automation only"라고 문서에 적혀 있으니 UI나 locust의 `--headless` 플래그 중 되는 쪽을 쓰고 기록하십시오.
- 기록할 것: 성공률(locust 실패 수), `Step_*`·`ResumeActor`·`SuspendActor`·`TimeToWake` 행의 p50/p99, 실패가 시작되는 세션 수와 오류 문구(`ResourceExhausted`, 503/504/429 등), worker pod 재시작·OOM 여부(`kubectl get pods -n benchmark-workloads`, `kubectl describe`).
- 서버가 버티면 내장 대본 `coding-session`(20단계, `--actor-memory 1Gi`)과 `personal-assistant-light`(`--agentsession-think-scale 0.02`로 하루를 약 30분에)도 한 번씩 돌리십시오.

### W4. 스토리지 부담 측정 (W2, W3 중 동시 수집)

1차 검증의 `agent-verify/scripts/collect.sh`를 기준으로 하되, **장치 이름**(`vda`가 아닐 것)과 **kind 노드의 디스크 경로**를 서버에 맞게 고치십시오.

수집할 것(1초 간격):
- `iostat -dxty 1 <장치>`: **`-t`를 꼭 넣어 타임스탬프를 찍으십시오.** 1차 검증에서 빠뜨려 구간 대응이 어려웠습니다.
- `pidstat -d -l 1`: 쓰기 주체. 1차 검증에서는 `runsc-sandbox ... boot` 프로세스가 snapshot 크기만큼 썼고, 이번에는 atelet의 objectstore-plugin과 rustfs 프로세스가 추가로 보여야 합니다.
- kind 노드 안 `du -sk /var/lib/ate/snapshots /var/lib/ate/actors /var/lib/ate/snapshot-cache`와 rustfs PVC(`/var/local-path-provisioner/...` 또는 `kubectl exec rustfs -- du -sk /data`) 크기.
- `free -k`와 kind 노드의 `/proc/meminfo`, 그리고 `kubectl ate get workers`의 `MEMORY` 열(allocated/capacity).
- `kubectl ate top workers`가 있으면 그 출력도.

답해야 할 질문:
- suspend 1회당 **로컬 쓰기**와 **객체 저장소 쓰기**가 각각 얼마인가. actor 메모리에 비례하는가. (1차 검증 gVisor 직접 측정: 로컬 쓰기 = 메모리 크기 × 1.00, 압축 none)
- 여러 actor가 동시에 suspend될 때 디스크 `%util`과 1초 피크 쓰기는 얼마인가. (1차: 256 MiB × 8개 동시에 1.39 GB/s, util 98%, 개별 suspend가 단독의 최대 5.7배로 늘어남)
- `async` 모드에서 업로드가 몰리는 시점은 언제인가. atelet 기본값은 업로드 지연 5분, 로컬 보관 30분(`cmd/atelet/internal/snapshottracker/background.go:34-37`). 측정 창을 그보다 길게 잡거나, atelet 플래그 `--snapshot-upload-delay`를 줄이는 것을 사용자 승인 후 고려하십시오.
- actor를 내리면 노드 메모리가 얼마나 회수되는가. (1차: gVisor checkpoint로 1 GiB 전부 회수)
- 방해 요소: 페이지 캐시 때문에 `iostat` 창별 값은 옆 창으로 샙니다. 총량과 `pidstat`로 교차 확인하십시오. kind는 컨테이너라 노드의 `/var/lib/ate`가 docker 데이터 디렉터리와 같은 디스크입니다. 전용 디스크가 있으면 `docs/guides/node-storage.md`대로 `/var/lib/ate/snapshots`에 mount하는 것이 깨끗한데, kind 노드 안이라 `extraMounts`로 넣어야 합니다(스크립트 수정, 사용자 승인).

### W5. gVisor runsc 직접 측정 재현 (비교용, 1시간 이내)

1차 검증의 `scripts/runsc_cr.sh`, `scripts/runsc_matrix.sh`, `memhold.c`를 그대로 쓰면 됩니다. 이 서버에서 다시 돌려 **KVM 플랫폼**(`--platform=kvm`)과 systrap을 비교하고, NVMe에서 피크 쓰기와 checkpoint 시간이 어떻게 달라지는지 적으십시오.
- runsc는 atelet이 받아 둔 `/var/lib/ate/sandbox-asset-cache/entries/<hash>/data/`에서 `runsc`와 `gvisor-bin/`을 같이 꺼내 쓰십시오(사이드카 없으면 `gvisor_sentry not usable` 오류).
- 스크립트의 알려진 결함: `runsc_matrix.sh`의 동시 시험 뒤 `wait`가 백그라운드 iostat까지 기다립니다. `wait $pid...`로 고치거나 iostat를 밖에서 돌리십시오.
- `runsc checkpoint --compression flate-best-speed`도 한 번 비교해 압축이 쓰기량과 시간에 주는 영향을 적으십시오.

### W6. Firecracker 직접 시험 (KVM 있을 때만, 시간이 남을 때)

1차 핸드오프의 V5와 같습니다. `docs/getting-started.md`, `docs/snapshotting/snapshot-support.md`. 재야 할 것: 256 MiB·1 GiB에서 Full snapshot 저장 시간·파일 크기(sparse이므로 `du`와 `ls -l` 둘 다)·복원 시간, `Diff` snapshot(`track_dirty_pages: true`)의 크기, 4개·8개 동시 저장.

### W7. E2B Embed (설치는 선택, 사용자 승인 후)

저장소는 `e2b-dev/runtime`, 설치 문서는 `embed/compose/README.md`. 요구 사양: KVM, cgroup v2, Ubuntu 24.04 권장, RAM 12 GiB, 디스크 20 GiB, Docker 27+. 설치하면 pause/resume 후 snapshot이 **어느 경로에 어떤 형식으로** 남는지만 확인하면 됩니다(1차 검증에서 못 찾은 것).

## 4. 1차 검증으로 알려진 내용 (확인 수준 표시)

| 주장 | 확인 수준 | 근거 |
|---|---|---|
| Agent Substrate는 1.0 도달. 태그 `v1.0.0`, 이미지 `ghcr.io/agent-substrate/substrate/<image>:<tag>` 공개 | 확인됨 | `README.md:85`, `docs/dev/releasing.md:3,44` |
| `ate-setup --image-repo ghcr.io/agent-substrate/substrate --image-tag v1.0.0`으로 ko 빌드 없이 설치 가능. 단 데모·벤치마크 이미지는 미공개라 소스 빌드 필요 | 문서로 확인 (실행 안 함) | `cmd/ate-setup/commands.md` "Installing pre-built images", `docs/dev/releasing.md:48` |
| kind 설치에 PodCertificateRequest, ClusterTrustBundle feature gate 필요. 스크립트가 켬 | 실행 확인 | `hack/create-kind-cluster.sh:105-111` |
| kind는 go run으로 자동, kubectl은 따로 설치 | 실행 확인 | `hack/kind.sh` |
| snapshot 저장: 노드 로컬 `/var/lib/ate/snapshots` → 객체 저장소 `<location>/atespaces/<atespace>/actors/<uid>/snapshots/<uuid>` (zstd 압축) | 문서·코드 확인, 파일은 못 봄 | `docs/guides/node-storage.md:18`, `docs/reference/api-guide.md` "Snapshot Storage Layout", `pkg/objectstorage/objects.go:264-266` |
| 백엔드는 `ATE_STORAGE_BACKEND=s3`면 S3 호환, 아니면 GCS. 로컬 디스크 전용 백엔드 없음 | 코드 확인 | `pkg/objectstorage/env.go:27-63` |
| kind는 클러스터 안 rustfs(S3 호환) 사용, 위치 `gs://ate-snapshots/`(URI 표기는 `gs://` 유지) | 실행 확인 | `manifests/ate-install/kind/rustfs.yaml`, `manifests/ate-install/kind/atelet/kustomization.yaml:65-69`, `cmd/ate-setup/internal/config/load.go:356-362` |
| 업로드는 `async`가 기본, atelet 업로드 지연 5분·detach 30분 | 코드 확인 | `cmd/atelet/internal/snapshottracker/background.go:34-37`, `cmd/atelet/main.go:136-137` |
| **ateworker-gvisor는 cgroup v2 전용** | 실행+코드 확인 | `internal/ateworker/cgroup/cgroup.go:62-72,131` |
| gVisor worker는 `runsc checkpoint`/`restore`를 실행 | 코드 확인 | `cmd/ateworker-gvisor/runsc.go:181,230` |
| gVisor `runsc checkpoint` 기본 압축 none → snapshot 크기 = 메모리 크기 | 실행 확인 | `runsc checkpoint --help`, `measure/runsc/results.txt` |
| gVisor checkpoint 시간: 64MiB 0.06s, 256MiB 0.31s, 512MiB 0.51s, 1GiB 0.76s. restore 0.09/0.16/0.24/0.41s (systrap, KVM 없음, 가상 디스크) | 실행 확인, 이 서버에서 다시 재야 함 | `VERIFICATION_REPORT.md` V2(b) |
| 동시 8개(256MiB) suspend: 1초 피크 1.39 GB/s, util 98%, 개별 최대 5.7배 느려짐 | 실행 확인 | `VERIFICATION_REPORT.md` V4 |
| agent-session 부하: `--user-class agentsession`, 대본 YAML, op 10종, `--agentsession-script-file` 있음, `locust/deploy.sh --agentsession-script FILE` 래퍼 있음 | 코드 확인 + 우리 대본 검증 통과 | `internal/benchmarking/boomer/agentsession/scriptfile.go`, `benchmarking/locust/common/agentsession_config.py:36-100`, `benchmarking/locust/deploy.sh:63,76-84` |
| 내장 대본: `coding-session`(20단계, 1Gi), `personal-assistant`(1536Mi, 하루 약 150 MiB 쓰기), `personal-assistant-light` | 파일 확인 | `internal/benchmarking/boomer/agentsession/scripts/` |
| 옵션 값: `--lifecycle-mode sync\|async\|none`, `--resume-mode explicit\|implicit`(코드 기본 explicit, 문서는 agent-session에서 implicit 기본이라 적어 불일치) | 코드 확인 | `benchmarking/locust/common/lifecycle_mode.py:27-31`, `resume_mode.py:27-30` |
| 벤치마크는 kind에서 돌릴 수 있음(`KO_DOCKER_REPO=localhost:5001`, 권한 부트스트랩 두 변수). nightly automation만 GCS 사용 | 문서 확인, 실행은 worker 문제로 못 함 | `docs/guides/benchmarking.md` |
| 단계별 시간 분해 도구: `Checkpoint timing breakdown` 로그 + `benchmarking/analysis/phase_report.py` | 문서 확인 | `docs/dev/suspend-resume-phase-breakdown.md` |
| 공개 시험 수치(GKE 2대, 20세션 실패 2.6%, 8 vCPU에서 7세션 초과 시 멈춤) | **미확인** | 1차 핸드오프 PR #1934 |
| Firecracker: Apache 2.0, KVM 필수, snapshot은 vmstate+memory 파일, Diff snapshot 지원 | 문서 확인 | `docs/getting-started.md:14,35`, `docs/snapshotting/snapshot-support.md` |
| E2B: 저장소 `e2b-dev/runtime`, Embed는 KVM·cgroup v2 필수, pause/resume 지원, 데이터는 그 서버 디스크. 정확한 저장 형식은 미확인 | 웹 확인 | `embed/README.md`, `embed/compose/README.md` |

**1차 검증에서 환경 때문에 겪었고 이 서버에서는 안 생길 가능성이 높은 것** (생기면 같은 우회가 `local-patches.diff`에 있음): kubelet의 `failCgroupV1`, runc의 `oom_score_adj` 거부, registry `[::1]` 바인딩, envoy/agentgateway의 `::` 리스너, 프록시 CA를 containerd·docker build·atelet에 등록, Docker Hub 429.

## 5. 결과 보고 형식

작업 폴더에 `VERIFICATION_REPORT_onprem.md`를 만드십시오. 규칙은 1차와 같습니다: 한국어, 영어 원문 병기, 짧은 문장, 표는 숫자에만, 모든 결과에 명령·출력·파일 경로와 줄 번호, 확인/추정 구분.

구성:
1. **한 줄 결론:** 이 서버에서 구축·측정이 되는가. 가능 / 조건부 가능 / 불가.
2. **W0 사전 조건 표**와 그로 인해 건너뛴 항목.
3. **항목별 결과 W1~W7.**
4. **핵심 질문에 대한 답:**
   - suspend/resume이 Substrate 경로로 끝까지 되는가. snapshot 파일은 로컬과 객체 저장소에 **실제로 무엇이** 남는가(파일명, 크기, 압축비).
   - 우리 대본으로 1·5·10·20 세션이 도는가. 성공률, 재개 시간 p50/p99, 실패 시작 지점.
   - suspend 1회 쓰기량(로컬/객체), 동시 suspend 피크, 메모리 회수량. 1차 검증 gVisor 직접 측정값과의 비교.
5. **4장의 주장 중 틀렸거나 달라진 것.**
6. **막힌 지점과 필요한 조치.**
7. **측정 숫자의 한계:** 규모, 반복, 디스크 종류, kind 컨테이너 때문에 생기는 왜곡.
8. **서버에 남긴 것과 지우는 방법.** `./hack/delete-kind-cluster.sh`, docker 이미지 목록, 설치한 패키지, `~/agent-verify`, `~/.kube`, `~/.cache/ate-setup`, `go install`로 들어간 `kubectl-ate`.

## 6. 하지 말아야 할 것

- 외부 클라우드 자원 생성, 유료 서비스 가입, 외부로의 데이터 전송 (rustfs 자격 증명 `rustfsadmin`은 평문이지만 클러스터 밖으로 노출하지 마십시오)
- 승인 없는 sudo 명령, sysctl 변경, atelet 플래그 변경, kind 스크립트 수정
- 이미 있는 클러스터나 다른 사람의 작업 영역 변경. `hack/create-kind-cluster.sh`는 이름이 `kind`인 기존 클러스터를 지웁니다. 있으면 `KIND_CLUSTER_NAME`을 바꾸십시오.
- 1차 검증의 환경 우회 패치를 증상 확인 없이 적용하는 일
- 결과를 좋게 보이려고 실패를 생략하거나, 실행하지 않은 것을 실행한 것처럼 쓰는 일
- 측정하지 않은 숫자를 추정해서 적는 일. 1차 검증 숫자를 이 서버의 숫자처럼 쓰는 일
