# LLM Katan Kubernetes Deployment

Complete Kubernetes deployment manifests for running LLM Katan instances as a mock LLM backend for Semantic Router testing and development.

## Overview

LLM Katan is a lightweight LLM inference server that uses real tiny models (e.g., Qwen3-0.6B) to provide OpenAI-compatible API endpoints. This deployment creates multiple instances simulating different LLM providers:

- **llm-katan-gpt**: Simulates `gpt-3.5-turbo`
- **llm-katan-claude**: Simulates `claude-3-haiku`
- **llm-katan-llama**: Simulates `Meta-Llama-3.1-8B`

All instances use the same tiny model but can be configured with different parameters (temperature, max_tokens, etc.) to simulate different behavior.

## Why Use LLM Katan Instead of Mock-vLLM?

| Feature                 | LLM Katan                    | Mock-vLLM                    |
| ----------------------- | ---------------------------- | ---------------------------- |
| **Real Inference**      | ✅ Actual model predictions  | ❌ Static echo responses     |
| **Semantic Testing**    | ✅ Real classification logic | ❌ No semantic understanding |
| **Token Statistics**    | ✅ Accurate tokenizer        | ⚠️ Approximate estimates     |
| **Streaming**           | ✅ Real streaming            | ⚠️ Simulated                 |
| **Prometheus Metrics**  | ✅ Built-in `/metrics`       | ❌ Not available             |
| **Performance Testing** | ✅ Real latency/throughput   | ❌ Not meaningful            |
| **Resource Usage**      | Low (1-2GB RAM)              | Minimal (<100MB)             |
| **Startup Time**        | ~30-60s (model loading)      | <5s                          |
| **Use Case**            | Integration/E2E testing      | Smoke testing                |

**Recommendation**: Use LLM Katan for comprehensive testing; use mock-vLLM only for quick smoke tests or CI where model loading time is critical.

## Architecture

```
┌─────────────────────┐
│  Semantic Router    │
│  (Envoy + Go)       │
└──────────┬──────────┘
           │ Routes requests
           │
    ┌──────┴───────┬──────────────┬──────────────┐
    │              │              │              │
┌───▼────┐    ┌───▼────┐    ┌───▼────┐    ┌────▼────┐
│ LLM    │    │ LLM    │    │ LLM    │    │ Prom-   │
│ Katan  │    │ Katan  │    │ Katan  │    │ etheus  │
│ (GPT)  │    │(Claude)│    │(Llama) │    │         │
└────┬───┘    └────┬───┘    └────┬───┘    └────┬────┘
     │             │             │              │
     └─────────────┴─────────────┴──────────────┘
              Scrapes /metrics
```

## Prerequisites

1. **Kubernetes cluster** (v1.23+)
2. **kubectl** configured
3. **HuggingFace token** (for model downloads)
   - Get from: https://huggingface.co/settings/tokens
4. **Optional**: Prometheus Operator (for ServiceMonitor)

## Quick Start

### 1. Create HuggingFace Token Secret

```bash
# Option A: Edit secret.yaml with your token
vim deploy/kubernetes/llm-katan/secret.yaml

# Option B: Create secret from command line (recommended)
kubectl create secret generic huggingface-token \
  --from-literal=token=hf_YOUR_TOKEN_HERE \
  --namespace vllm-semantic-router-system

# Verify secret
kubectl get secret huggingface-token -n vllm-semantic-router-system
```

### 2. Deploy LLM Katan Instances

```bash
# Deploy all instances
kubectl apply -k deploy/kubernetes/llm-katan/

# Verify deployments
kubectl get pods -n vllm-semantic-router-system -l app=llm-katan

# Check logs
kubectl logs -n vllm-semantic-router-system -l app=llm-katan -f
```

### 3. Verify Services

```bash
# Check all services
kubectl get svc -n vllm-semantic-router-system -l app=llm-katan

# Port-forward to test locally
kubectl port-forward -n vllm-semantic-router-system svc/llm-katan-gpt 8100:8000

# Test endpoint
curl http://localhost:8100/v1/models
curl http://localhost:8100/health
curl http://localhost:8100/metrics
```

### 4. Test Chat Completion

```bash
# Test GPT instance
curl -X POST http://localhost:8100/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-3.5-turbo",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 50
  }'

# Port-forward to Claude instance
kubectl port-forward -n vllm-semantic-router-system svc/llm-katan-claude 8101:8000

# Test Claude instance
curl -X POST http://localhost:8101/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-3-haiku",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

## Configuration

### Modify Model Configuration

Edit `configmap.yaml` to change default settings:

```yaml
data:
  default_model: "Qwen/Qwen3-0.6B" # Change to different tiny model
  backend: "transformers" # or "vllm"
  max_tokens: "512"
  temperature: "0.7"
```

Apply changes:

```bash
kubectl apply -f deploy/kubernetes/llm-katan/configmap.yaml
kubectl rollout restart deployment -n vllm-semantic-router-system -l app=llm-katan
```

### Adjust Resource Limits

Edit `deployment.yaml` or use kustomize patches:

```yaml
resources:
  requests:
    memory: "2Gi" # Increase for larger models
    cpu: "1000m"
  limits:
    memory: "4Gi"
    cpu: "2000m"
```

### Enable Autoscaling

```bash
# Uncomment hpa.yaml in kustomization.yaml
kubectl apply -k deploy/kubernetes/llm-katan/

# Monitor HPA
kubectl get hpa -n vllm-semantic-router-system -l app=llm-katan -w
```

## Monitoring Integration

### With Prometheus Operator (Recommended)

The deployment includes a `ServiceMonitor` that automatically configures Prometheus to scrape metrics:

```bash
# Verify ServiceMonitor
kubectl get servicemonitor -n vllm-semantic-router-system llm-katan

# Check Prometheus targets
kubectl port-forward -n monitoring svc/prometheus 9090:9090
# Visit: http://localhost:9090/targets
```

### Manual Prometheus Configuration

If not using Prometheus Operator, update Prometheus ConfigMap:

```yaml
scrape_configs:
  - job_name: "llm-katan"
    kubernetes_sd_configs:
      - role: endpoints
        namespaces:
          names:
            - vllm-semantic-router-system
    relabel_configs:
      - source_labels: [__meta_kubernetes_service_label_app]
        regex: llm-katan
        action: keep
      - source_labels: [__meta_kubernetes_endpoint_port_name]
        regex: metrics
        action: keep
```

### Available Metrics

LLM Katan exposes the following Prometheus metrics at `/metrics`:

```promql
# Total requests processed
llm_katan_requests_total{model="gpt-3.5-turbo",backend="transformers"}

# Total tokens generated
llm_katan_tokens_generated_total{model="gpt-3.5-turbo",backend="transformers"}

# Average response time
llm_katan_response_time_seconds{model="gpt-3.5-turbo",backend="transformers"}

# Server uptime
llm_katan_uptime_seconds{model="gpt-3.5-turbo",backend="transformers"}
```

### Example Grafana Queries

```promql
# Request rate per model
rate(llm_katan_requests_total[5m])

# Token generation rate
rate(llm_katan_tokens_generated_total[5m])

# Average response time (p95)
histogram_quantile(0.95, rate(llm_katan_response_time_seconds[5m]))

# Total requests by instance
sum by (instance_name, model) (llm_katan_requests_total)
```

## Integration with Semantic Router

### Update Semantic Router Configuration

Modify `config/config.yaml` to use LLM Katan endpoints:

```yaml
models:
  - name: gpt-3.5-turbo
    endpoint: http://llm-katan-gpt.vllm-semantic-router-system.svc.cluster.local:8000
    api_type: openai

  - name: claude-3-haiku
    endpoint: http://llm-katan-claude.vllm-semantic-router-system.svc.cluster.local:8000
    api_type: openai

  - name: Meta-Llama-3.1-8B
    endpoint: http://llm-katan-llama.vllm-semantic-router-system.svc.cluster.local:8000
    api_type: openai
```

### Test End-to-End

```bash
# Deploy semantic router with llm-katan backends
kubectl apply -k deploy/kubernetes/

# Run E2E tests
kubectl exec -it -n vllm-semantic-router-system deployment/semantic-router -- \
  curl localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "gpt-3.5-turbo", "messages": [{"role": "user", "content": "Test"}]}'
```

## Troubleshooting

### Pods Not Starting

```bash
# Check pod status
kubectl describe pod -n vllm-semantic-router-system -l app=llm-katan

# Common issues:
# 1. Missing HuggingFace token
kubectl get secret huggingface-token -n vllm-semantic-router-system

# 2. Insufficient resources
kubectl top pods -n vllm-semantic-router-system -l app=llm-katan

# 3. Image pull errors
kubectl get events -n vllm-semantic-router-system --sort-by='.lastTimestamp'
```

### Model Download Failures

```bash
# Check logs for HuggingFace errors
kubectl logs -n vllm-semantic-router-system -l app=llm-katan --tail=100

# Verify token validity
kubectl exec -it deployment/llm-katan-gpt -n vllm-semantic-router-system -- \
  env | grep HUGGINGFACE
```

### Health Check Failures

```bash
# Test health endpoint directly
kubectl exec -it deployment/llm-katan-gpt -n vllm-semantic-router-system -- \
  curl -v http://localhost:8000/health

# Adjust startup probe if model loading takes longer
# Edit deployment.yaml:
startupProbe:
  initialDelaySeconds: 30  # Increase this
  failureThreshold: 20     # And this
```

### Performance Issues

```bash
# Check resource usage
kubectl top pods -n vllm-semantic-router-system -l app=llm-katan

# Scale up replicas
kubectl scale deployment llm-katan-gpt -n vllm-semantic-router-system --replicas=3

# Enable HPA for automatic scaling
kubectl apply -f deploy/kubernetes/llm-katan/hpa.yaml
```

## Advanced Usage

### Use vLLM Backend

For better performance, switch to vLLM backend:

```yaml
# Edit configmap.yaml
data:
  backend: "vllm"

# Or override in deployment.yaml command
command:
  - llm-katan
  - --backend
  - vllm
  - --model
  - $(YLLM_MODEL)
```

**Note**: vLLM requires GPU support. Add to deployment:

```yaml
resources:
  limits:
    nvidia.com/gpu: 1
```

### Multiple Model Variants

Deploy different models for different instances:

```yaml
# In deployment.yaml, change model per instance
command:
  - llm-katan
  - --model
  - TinyLlama/TinyLlama-1.1B-Chat-v1.0 # Different model
  - --served-model-name
  - gpt-4-turbo
```

### Custom Network Policies

Restrict access to LLM Katan instances:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: llm-katan-policy
spec:
  podSelector:
    matchLabels:
      app: llm-katan
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: semantic-router
      ports:
        - protocol: TCP
          port: 8000
```

## Cleanup

```bash
# Delete all llm-katan resources
kubectl delete -k deploy/kubernetes/llm-katan/

# Or delete individually
kubectl delete deployment -n vllm-semantic-router-system -l app=llm-katan
kubectl delete svc -n vllm-semantic-router-system -l app=llm-katan
kubectl delete secret huggingface-token -n vllm-semantic-router-system
```

## Migration from Mock-vLLM

### Step-by-Step Migration

1. **Deploy LLM Katan alongside mock-vllm**:

   ```bash
   # Keep both running temporarily
   kubectl apply -k deploy/kubernetes/llm-katan/
   ```

2. **Update Semantic Router config to use LLM Katan**:

   ```yaml
   # Change from:
   endpoint: http://mock-vllm:8000
   # To:
   endpoint: http://llm-katan-gpt:8000
   ```

3. **Test thoroughly**:

   ```bash
   # Run E2E tests
   ./e2e-tests/run_all_tests.py
   ```

4. **Monitor metrics**:

   ```bash
   # Compare mock-vllm vs llm-katan metrics
   kubectl port-forward svc/prometheus 9090:9090
   ```

5. **Remove mock-vllm**:

   ```bash
   kubectl delete deployment mock-vllm -n vllm-semantic-router-system
   ```

### Configuration Differences

| Aspect          | Mock-vLLM    | LLM Katan              |
| --------------- | ------------ | ---------------------- |
| Service name    | `mock-vllm`  | `llm-katan-{instance}` |
| Port            | 8000         | 8000                   |
| Health endpoint | `/health`    | `/health`              |
| Models endpoint | `/v1/models` | `/v1/models`           |
| Metrics         | ❌           | `/metrics`             |
| Startup time    | <5s          | 30-60s                 |
| Memory          | <100MB       | 1-2GB                  |

## Best Practices

1. **Pin Image Versions**: Use specific tags instead of `latest` in production
2. **Resource Limits**: Set appropriate CPU/memory based on your model size
3. **Health Checks**: Adjust probe timings based on model loading time
4. **Secrets Management**: Use external secret managers (Vault, AWS Secrets Manager)
5. **Monitoring**: Always enable Prometheus scraping and alerting
6. **Autoscaling**: Enable HPA for production workloads
7. **Network Policies**: Restrict access to only necessary services

## Contributing

To add new model instances:

1. Copy an existing deployment block in `deployment.yaml`
2. Update instance name, served model name, and parameters
3. Add corresponding Service in `service.yaml`
4. Update `configmap.yaml` if needed
5. Test locally with port-forwarding before committing

## Related Documentation

- [LLM Katan PyPI Package](https://github.com/vllm-project/semantic-router/tree/main/e2e-tests/llm-katan)
- [Semantic Router Kubernetes Deployment](../README.md)
- [Observability Setup](../observability/README.md)
- [E2E Testing Guide](../../e2e-tests/README.md)

## License

Apache-2.0
