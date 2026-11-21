# backup-vps-google-drive

Skill do Claude Code para configurar backup diário de um VPS Linux no Google Drive com o rclone:
todos os sites e todos os bancos MySQL/MariaDB, com conferência, limpeza do que venceu e aviso por
e-mail (na falha, um "Backup OK" por dia e um resumo por semana).

Também serve sem o Claude: os scripts em `scripts/` são shell puro e o passo a passo está em
`SKILL.md`.

## Instalar a skill

```bash
git clone <url-deste-repositorio> ~/.claude/skills/backup-vps-google-drive
```

Ponto de entrada: `SKILL.md`. Peça ao Claude "configura o backup do servidor no Google Drive".

## Conteúdo

- `SKILL.md`: pré-requisitos, passo a passo com a prova de cada etapa, como restaurar e os erros
  mais comuns.
- `referencias/google-drive.md`: como criar a chave própria no Google Cloud, publicar o app e
  autorizar o rclone num servidor sem navegador, com acesso restrito à pasta do backup.
- `scripts/`: cinco scripts e um arquivo de configuração de exemplo.

## Requisitos do servidor

Linux com bash, `rclone`, `mysqldump`, `tar`, `jq`, `sendmail` (Postfix) e cron.
Testado em AlmaLinux 9 com MariaDB 10.11 e rclone 1.75.

## Avisos

- Nenhum arquivo daqui contém credencial. Senha do banco fica em `/root/.my.cnf` e a autorização
  do Drive em `rclone.conf`, os dois fora do repositório.
- Os scripts apagam do Drive os backups mais velhos que o prazo configurado. Confira os prazos em
  `backup-drive.conf` antes de agendar.
- Teste a restauração. Backup que nunca foi restaurado é só uma esperança.

## Licença

MIT. Veja `LICENSE`.
