# Cilium в kind: что включено и почему

Ноды kind — это Docker-контейнеры на общем ядре VM (здесь Ubuntu 24.04, ядро 6.8, arm64). У каждой ноды `eth0` — veth в docker-bridge `kind`.

| Параметр | Значение | Работает в kind? | Комментарий |
|---|---|---|---|
| `kubeProxyReplacement` | `true` | да | ClusterIP, NodePort, HostPort, externalIPs на eBPF. Кластер создаётся с `kubeProxyMode: none` |
| `k8sServiceHost/Port` | `dev01-control-plane:6443` | да | Обязательно без kube-proxy. Имя резолвится docker DNS в сети `kind` |
| `socketLB.enabled` | `true` | да | Балансировка на `connect()` в cgroup v2. Подам не нужен DNAT по пакетам |
| `bpf.masquerade` | `true` | да | SNAT на eBPF вместо iptables MASQUERADE |
| `bpf.hostLegacyRouting` | `false` | да (ядро ≥ 5.10) | eBPF host routing, пакеты не проходят netfilter хоста. Если с хоста/ноды что-то не будет работать, первым делом вернуть `true` |
| `loadBalancer.mode` | `snat` | да | `dsr`/`hybrid` требуют native routing (или geneve-DSR) и в kind ничего не дают |
| `loadBalancer.acceleration` | `disabled` | нет | XDP на veth нод kind не ускоряет и native XDP не поддерживается |
| LoadBalancer-сервисы | не используем | частично | LB-IPAM выдаст IP, но с macOS хоста до docker-сети VM он недоступен без L2 announcements и маршрутов |
| `routingMode` | `tunnel` (vxlan) | да | Native routing в kind возможен (`autoDirectNodeRoutes`, все ноды в одной L2), но для лаборатории туннель проще |
| `policyAuditMode` | `false` (enforce с 2026-11-15) | да | Для отладки новых политик временно `true`: нарушения видны как `AUDIT` в Hubble |

Проверка:

    make cilium-kpr   # KubeProxyReplacement: True, Routing: Host: BPF, Masquerading: BPF

Ограничения kind:
- при пересоздании кластера обязателен `networking.kubeProxyMode: none` в kind-конфиге (`cluster/kind-dev01.yaml.tmpl`). Иначе поднимется kube-proxy и будет конфликтовать с KPR;
- до установки Cilium ноды остаются `NotReady`, а ClusterIP `10.96.0.1` не работает. Это нормально.
