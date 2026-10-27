# Kubernetes External Access

Automação da exposição de serviços em clusters Kubernetes utilizando MetalLB, NGINX Ingress Controller e Headlamp. O projeto permite disponibilizar uma interface web de gerenciamento do cluster por meio de um endereço IP externo e de regras de roteamento HTTP.

A configuração foi desenvolvida para um ambiente Kubernetes executado em Linux, utilizando o modo IPVS do `kube-proxy` e o MetalLB em modo Layer 2 para anunciar endereços IP na rede local.

## Arquitetura

O fluxo de acesso é composto pelos seguintes componentes:

1. **MetalLB:** gerencia a alocação de endereços IP externos para serviços do tipo `LoadBalancer` e anuncia esses endereços na rede local.
    
2. **NGINX Ingress Controller:** recebe as requisições HTTP e encaminha o tráfego conforme as regras Ingress configuradas.
    
3. **Headlamp:** fornece uma interface web para visualização e gerenciamento de recursos Kubernetes.
    
4. **kube-proxy com IPVS:** implementa o encaminhamento de tráfego dos serviços Kubernetes, com `strictARP` habilitado para o cenário de anúncio Layer 2.
    

## Arquivos do repositório

|Arquivo|Descrição|
|---|---|
|`install.sh`|Automatiza a instalação e a configuração dos componentes.|
|`uninstall.sh`|Automatiza a remoção dos componentes instalados pelo projeto.|
|`IPPool.yaml`|Define o `IPAddressPool` e o `L2Advertisement` utilizados pelo MetalLB.|
|`headlamp-ingress.yaml`|Define a regra de roteamento HTTP para o serviço Headlamp.|

## 1. Pré-requisitos

Antes de iniciar, verifique se o ambiente possui:

- Cluster Kubernetes operacional.
    
- `kubectl` configurado com permissões suficientes para modificar os recursos do cluster.
    
- Helm instalado.
    
- Linux nos nós em que os módulos IPVS serão habilitados.
    
- Python 3 e PyYAML disponíveis no ambiente de execução do script, caso a configuração automatizada do `kube-proxy` seja utilizada.
    
- Endereços IP reservados para o MetalLB e disponíveis na rede local.
    
- Conectividade entre a rede cliente, os nós Kubernetes e o endereço IP externo.
    
- Os quatro arquivos deste repositório disponíveis no mesmo diretório.
    

O ambiente de referência utiliza Kubernetes `v1.34.x`, MetalLB `v0.15.3` e NGINX Ingress Controller `2.5.1`. Verifique a compatibilidade das versões com a distribuição Kubernetes utilizada.

Confirme o contexto ativo antes de executar alterações:

```
kubectl config current-context
kubectl get nodes
helm version
```

## 2. Configuração do ambiente

O script de instalação automatiza a configuração do `kube-proxy`, a instalação dos componentes, a aplicação dos manifestos e as verificações finais.

Por padrão, a configuração dos módulos do kernel não é executada pelo script, pois ele não pressupõe acesso administrativo a todos os nós do cluster. Os módulos IPVS devem estar carregados em cada nó relevante.

Em cada nó Linux, execute:

```
sudo modprobe ip_vs
sudo modprobe ip_vs_rr
sudo modprobe ip_vs_wrr
sudo modprobe ip_vs_sh
sudo modprobe nf_conntrack
```

Para persistir o carregamento após a reinicialização:

```
printf "ip_vs\nip_vs_rr\nip_vs_wrr\nip_vs_sh\nnf_conntrack\n" \
  | sudo tee /etc/modules-load.d/ipvs.conf
```

Verifique os módulos carregados:

```
lsmod | grep -E 'ip_vs|nf_conntrack'
```

Caso deseje utilizar o script para configurar também a máquina em que ele é executado, defina `CONFIGURE_LOCAL_NODE=true`. Essa opção não configura automaticamente os demais nós Kubernetes.

## 3. Configuração do kube-proxy

Por padrão, o script ajusta o ConfigMap `kube-proxy` para utilizar IPVS e habilitar `strictARP`.

As propriedades configuradas são:

```
mode: "ipvs"
ipvs:
  strictARP: true
```

A alteração preserva as demais propriedades da configuração processada pelo script. Em seguida, os pods do `kube-proxy` são recriados para carregar as novas configurações.

O script utiliza Python com PyYAML para modificar o YAML armazenado no ConfigMap. Caso essa dependência não esteja instalada, providencie-a antes da execução.

Para pular a configuração automatizada do `kube-proxy`:

```
KUBEPROXY_CONFIGURE=false ./install.sh
```

Essa opção pressupõe que o `kube-proxy` já esteja configurado conforme as necessidades do ambiente. Se necessário, realize a configuração manualmente antes de prosseguir.

**Importante:** antes de modificar o `kube-proxy`, recomenda-se salvar a configuração original para permitir uma restauração manual caso seja necessário.

```
kubectl get configmap kube-proxy -n kube-system -o yaml \
  > kube-proxy-backup.yaml
```

## 4. Instalação

Dê permissão de execução aos scripts:

```
chmod +x install.sh uninstall.sh
```

Execute a instalação:

```
./install.sh
```

O script realiza as seguintes operações:

1. Verifica as dependências, os manifestos e o acesso ao cluster.
    
2. Configura os módulos IPVS na máquina local, caso essa opção esteja habilitada.
    
3. Ajusta o `kube-proxy` para IPVS e `strictARP`, quando habilitado.
    
4. Instala o MetalLB e aguarda a inicialização dos componentes.
    
5. Aplica o `IPPool.yaml`.
    
6. Instala ou atualiza o NGINX Ingress Controller com o tipo de serviço `LoadBalancer`.
    
7. Instala ou atualiza o Headlamp por meio do Helm.
    
8. Aplica o `headlamp-ingress.yaml`.
    
9. Verifica os recursos implantados e realiza um teste HTTP de roteamento.
    

O script utiliza variáveis de ambiente para permitir ajustes nas versões, no endereço IP externo e no host utilizado pelo Headlamp.

## 5. Configuração do endereço IP externo

O arquivo `IPPool.yaml` define uma faixa de endereços disponível para o MetalLB:

```
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: metallb-single-ip
  namespace: metallb-system
spec:
  addresses:
    - 192.168.1.240-192.168.1.250
  autoAssign: false
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: metallb-single-ip-adv
  namespace: metallb-system
spec:
  ipAddressPools:
    - metallb-single-ip
```

O endereço externo utilizado como exemplo é `192.168.1.240`, que deve estar disponível dentro do intervalo configurado.

Para definir o endereço durante a instalação:

```
EXTERNAL_IP=192.168.1.240 ./install.sh
```

O endereço informado deve pertencer à faixa definida em `IPPool.yaml`, ser compatível com a rede local e não conflitar com endereços utilizados por outros dispositivos ou distribuídos pelo DHCP.

O manifesto também define o recurso `L2Advertisement`, responsável por configurar o anúncio dos endereços na rede local.

## 6. Acesso ao Headlamp

O arquivo `headlamp-ingress.yaml` define uma regra Ingress para o host `headlamp.local`, encaminhando as requisições para o serviço `my-headlamp`, na porta 80, dentro do namespace `kube-system`.

Para acessar a interface pelo navegador, configure a resolução do nome `headlamp.local` para o endereço IP externo. Em um cliente Linux, adicione a seguinte entrada ao arquivo `/etc/hosts`:

```
192.168.1.240 headlamp.local
```

Em seguida, acesse:

```
http://headlamp.local
```

Também é possível testar diretamente o roteamento HTTP, enviando o cabeçalho `Host`:

```
curl -H "Host: headlamp.local" http://192.168.1.240/
```

Uma resposta HTTP indica que houve comunicação com o ponto de entrada. Para confirmar o funcionamento completo, verifique se a resposta corresponde à aplicação Headlamp e se os recursos Kubernetes necessários estão operacionais.

**Nota sobre HTTPS:** o manifesto de exemplo contém uma anotação referente ao cert-manager, mas não define uma seção `tls` no Ingress. Portanto, a configuração apresentada neste tutorial demonstra o acesso HTTP. O uso de HTTPS exige configuração adicional de TLS, incluindo certificado e os recursos necessários no ambiente.

## 7. Validação da instalação

Após a execução, verifique os componentes do MetalLB:

```
kubectl get pods -n metallb-system
kubectl get ipaddresspools,l2advertisements -n metallb-system
```

Verifique o NGINX Ingress Controller:

```
kubectl get pods -n nginx-ingress
kubectl get svc -n nginx-ingress
```

Verifique o Headlamp e a regra Ingress:

```
kubectl get pods,svc -n kube-system
kubectl get ingress -n kube-system
```

O serviço do NGINX deve apresentar o endereço configurado na coluna `EXTERNAL-IP`.

## 8. Diagnóstico

Caso a instalação não funcione como esperado, consulte o estado dos recursos e os eventos do cluster.

### Endereço externo em `Pending`

```
kubectl get svc -n nginx-ingress
kubectl get ipaddresspools,l2advertisements -n metallb-system
kubectl get pods -n metallb-system
```

Verifique se o endereço solicitado pertence ao pool do MetalLB e se os componentes de anúncio estão operacionais.

### Problemas no roteamento HTTP

```
kubectl get ingress -n kube-system
kubectl describe ingress headlamp -n kube-system
kubectl get svc -n kube-system
```

Confira se a classe Ingress, o nome do serviço de destino e a porta configurada em `headlamp-ingress.yaml` correspondem aos recursos instalados.

### Problemas na configuração IPVS

```
kubectl get configmap kube-proxy -n kube-system -o yaml
kubectl get pods -n kube-system -l k8s-app=kube-proxy
```

Verifique se `mode` está definido como `ipvs`, se `strictARP` está habilitado e se os pods do `kube-proxy` estão operacionais.

### Problemas nos componentes do NGINX

```
kubectl get pods -n nginx-ingress
kubectl get svc -n nginx-ingress
helm list -n nginx-ingress
```

Para consultar os logs, identifique primeiro o nome do pod do controlador:

```
kubectl get pods -n nginx-ingress
kubectl logs -n nginx-ingress <nome-do-pod>
```

Os nomes dos serviços e os seletores utilizados nos comandos de diagnóstico podem variar conforme a versão e os valores do chart instalados.

## 9. Desinstalação

O repositório inclui o script `uninstall.sh` para automatizar a remoção dos componentes instalados pelo projeto.

Execute:

```
./uninstall.sh
```

O script solicita confirmação antes de prosseguir. Para executar sem a confirmação interativa:

```
./uninstall.sh --yes
```

O processo de desinstalação contempla:

1. Remoção do Ingress do Headlamp.
    
2. Desinstalação do release Helm do Headlamp.
    
3. Desinstalação do release Helm do NGINX Ingress Controller.
    
4. Remoção do `IPAddressPool` e do `L2Advertisement` definidos pelo projeto.
    
5. Remoção da instalação do MetalLB.
    

O script verifica se os releases Helm e os recursos esperados existem antes de tentar removê-los.

### Cuidados durante a desinstalação

- **MetalLB compartilhado:** a remoção da instalação do MetalLB pode afetar outros serviços `LoadBalancer` do cluster. Confirme que nenhum outro serviço depende dele antes de executar o script.
    
- **Configuração do kube-proxy:** o script de desinstalação não restaura automaticamente a configuração original do `kube-proxy`. Caso seja necessário reverter a alteração para IPVS, utilize o backup da configuração e planeje a restauração de acordo com a distribuição Kubernetes.
    
- **Módulos IPVS:** os módulos carregados no Linux e o arquivo `/etc/modules-load.d/ipvs.conf` não são removidos automaticamente.
    
- **Recursos compartilhados:** verifique se o namespace e os recursos do cluster são utilizados por outras aplicações antes de realizar limpezas adicionais.
    

A desinstalação dos componentes não significa que todas as alterações feitas no ambiente foram revertidas. Revise o estado do cluster após a execução.

## 10. Considerações de segurança e operação

- O intervalo de endereços IP utilizado deve estar disponível e ser compatível com a rede local.
    
- A configuração dos módulos do kernel precisa ser persistida em todos os nós relevantes.
    
- O script pressupõe permissões administrativas no cluster e pode alterar componentes de rede.
    
- Uma única réplica do NGINX Ingress Controller não garante alta disponibilidade.
    
- O Headlamp oferece acesso administrativo conforme as permissões associadas à identidade utilizada. Proteja o acesso e evite expor a interface em redes não confiáveis.
    
- O teste HTTP não substitui a configuração de HTTPS, autenticação e autorização.
    
- A execução repetida do script de instalação utiliza operações de instalação ou atualização do Helm, mas não garante reversão automática de alterações parcialmente aplicadas.
    
- Antes de utilizar os scripts em um ambiente compartilhado ou de produção, revise os manifestos e as alterações realizadas no cluster.
    

## Objetivo

Este projeto serve como referência prática para automatizar a publicação de serviços web em clusters Kubernetes, combinando alocação de endereços IP, anúncio Layer 2 e roteamento HTTP.

Embora o exemplo utilize o Headlamp, a infraestrutura pode ser adaptada para disponibilizar outras aplicações e APIs compatíveis com Ingress.