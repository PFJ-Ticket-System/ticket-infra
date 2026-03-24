# Ticket System Infrastructure

Infraestrutura completa de serviços para o Ticket System utilizando Docker Compose.

## Serviços Inclusos

- **PostgreSQL** - Banco de dados principal (porta 5432)
- **MongoDB** - Banco de dados NoSQL (porta 27017)
- **Redis** - Cache em memória (porta 6379)
- **RabbitMQ** - Message broker (porta 5672, UI em 15672)
- **Kafka** - Event streaming (porta 9093)
- **Keycloak** - Autenticação e autorização (porta 8080)

---

## 🔐 Configuração Keycloak

O Keycloak é inicializado automaticamente com uma configuração pré-definida através do arquivo `Keycloak/realm-export.json`.

### Estrutura de Autenticação

**Realm:** `ticket`

**Roles:**
- `admin` - Acesso total
- `customer` - Acesso padrão (role default)

**Clients:**
1. **ticket-frontend** (WebApp)
   - Type: Public
   - Protocol: OpenID Connect
   - URLs: 
     - Redirect: `http://localhost:3000/*`, `http://localhost:5000/*`
     - Web Origins: `http://localhost:3000`, `http://localhost:5000`
   - Security: PKCE (S256) ativado

2. **ticket-gateway** (Internal)
   - Type: Confidential
   - Service Account: Habilitado
   - ⚠️ **Secret precisa ser configurado**

---

## ⚙️ Setup

### 1. Clonar o Repositório

```bash
git clone <repository-url>
cd ticket-infra
```

### 2. Configurar Variáveis de Ambiente

#### Copiar arquivo de exemplo (se existir):
```bash
cp .env.example .env
```

#### Ou criar manualmente:
O arquivo `.env` já existe no repositório. Verifique se contém todas as variáveis necessárias:

```env
POSTGRES_PASSWORD=postgres
MONGO_ROOT_PASSWORD=root
REDIS_PASSWORD=redispass
KEYCLOAK_ADMIN_PASSWORD=admin
KC_DB_PASSWORD=keycloak
RABBITMQ_PASSWORD=rabbitmqpass
```

> **⚠️ Importante:** O arquivo `.env` não é monitorado pelo Git. As alterações locais nele são ignoradas pelo controle de versão.

### 3. Configurar Keycloak

O arquivo `Keycloak/realm-export.json` contém um placeholder para o secret do client `ticket-gateway`:

```json
"secret": "CHANGE_ME_BEFORE_RUNNING"
```

**Você DEVE alterar este valor antes de rodar:**

1. Abra `Keycloak/realm-export.json`
2. Procure por `"CHANGE_ME_BEFORE_RUNNING"` (linha ~60)
3. Substitua por um valor seguro:
   ```json
   "secret": "seu-secret-super-seguro-aqui"
   ```

**Exemplo de secret seguro:**
```
sk_test_51NzYw9AXXxxxxxxxxxxxxxxxxxxxx
```

### 4. Iniciar os Serviços

```bash
docker-compose up -d
```

Aguarde aproximadamente 30-45 segundos para todos os serviços ficarem healthy.

### 5. Verificar Status

```bash
docker-compose ps
```

Todos os containers devem estar com status `Up (healthy)`.

---

## 🌐 Acessar Keycloak

**URL:** http://localhost:8080

**Admin Console:**
- Usuário: `admin`
- Senha: valor configurado em `KEYCLOAK_ADMIN_PASSWORD` no `.env`

**Realm Padrão:** `ticket`

---

## 📋 Verificações Pós-Setup

### Keycloak está rodando?
```bash
curl -f http://localhost:8080/health/ready
```

### PostgreSQL está acessível?
```bash
docker exec ticket-keycloak-postgres psql -U keycloak -d keycloak -c "SELECT 1"
```

### Realm foi importado?
1. Acesse http://localhost:8080/admin
2. Selecione o realm `ticket` no dropdown superior esquerdo

---

## 🛑 Parar os Serviços

```bash
docker-compose down
```

### Remover volumes (limpar dados):
```bash
docker-compose down -v
```

---

## 📝 Notas Importantes

- **Segurança:** Todas as senhas no `.env` devem ser alteradas antes de colocar em produção
- **Keycloak:** O arquivo `realm-export.json` é essencial para o setup. Não remova
- **Dados:** Volumes nomeados preservam dados entre reinicializações
- **Rede:** Todos os serviços estão na rede `ticket-network` para comunicação interna

---

## 🔧 Troubleshooting

### Keycloak não importar o realm
Certifique-se de que:
- [ ] O caminho `./Keycloak/realm-export.json` está correto
- [ ] O arquivo JSON é válido
- [ ] O secret foi alterado (não pode estar como placeholder)

### Porta 8080 já está em uso
```bash
# Altere a porta no docker-compose.yml:
ports:
  - "8081:8080"  # acesse em http://localhost:8081
```

### PostgreSQL (Keycloak) não conecta
```bash
# Verifique o container
docker logs ticket-keycloak-postgres

# Ou reinicie
docker-compose restart keycloak-db keycloak
```

---

## 📚 Documentação Adicional

- [Keycloak Docs](https://www.keycloak.org/documentation)
- [Docker Compose Docs](https://docs.docker.com/compose)
