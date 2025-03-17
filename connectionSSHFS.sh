#!/bin/bash

# Colori per l'output
RED='\e[31m'
GREEN='\e[32m'
BLUE='\e[36m'
YELLOW='\e[33m'
BOLD='\e[1m'
RESET='\e[0m'

# Funzione di aiuto
show_help() {
    echo -e "${BOLD}Uso: $0 [OPZIONI] [NOME_CONNESSIONE]${RESET}"
    echo
    echo "Opzioni:"
    echo "  -h, --help             Mostra questo messaggio di aiuto"
    echo "  -l, --list             Lista delle connessioni salvate"
    echo "  -a, --add              Aggiungi una nuova connessione"
    echo "  -r, --remove NOME      Rimuovi una connessione esistente"
    echo "  -m, --modify NOME      Modifica una connessione esistente"
    echo "  -s, --status           Mostra lo stato delle connessioni attive"
    echo "  --auto-mount NOME      Configura il montaggio automatico all'avvio"
    echo "  --setup-alias          Configura l'alias 'sshfs_connect' per questo script"
    echo "  --ssh NOME             Apri una connessione SSH alla connessione specificata"
    echo
}

# Funzione per verificare le dipendenze
check_dependencies() {
    local deps=("sshfs" "jq")
    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        echo -e "${YELLOW}Installazione delle dipendenze mancanti:${RESET}"
        for pkg in "${missing[@]}"; do
            echo -e "${BLUE}Installazione di $pkg...${RESET}"
            sudo apt-get update &> /dev/null
            sudo apt-get install -y "$pkg"
            if [ $? -ne 0 ]; then
                echo -e "${RED}Errore: impossibile installare $pkg.${RESET}"
                exit 1
            fi
        done
    fi
}

# Controlla se SSHFS è installato e installalo se necessario
if ! command -v sshfs &> /dev/null; then
    echo "SSHFS non è installato. Installazione in corso..."
    sudo apt-get update
    sudo apt-get install sshfs
    if [[ $? -ne 0 ]]; then
        echo "Errore: impossibile installare SSHFS."
        exit 1
    fi
    echo "SSHFS installato con successo."
fi

# Controlla se JQ è installato e installalo se necessario
if ! command -v jq &> /dev/null; then
    echo "JQ non è installato. Installazione in corso..."
    sudo apt-get update
    sudo apt-get install jq
    if [[ $? -ne 0 ]]; then
        echo "Errore: impossibile installare JQ."
        exit 1
    fi
    echo "JQ installato con successo."
fi

# Funzione per aggiungere una nuova connessione
add_connection() {
    local name=$1
    local identity_file=$2
    local port=$3
    local user_host=$4
    local remote_path=$5
    local local_path=$6

    local config_file="$HOME/.sshfs/config.json"

    # Crea la directory .sshfs se non esiste
    mkdir -p "$(dirname "$config_file")"

    # Crea il file config.json se non esiste
    if [[ ! -f "$config_file" ]]; then
        echo "{}" > "$config_file"
    fi

    # Leggi il file JSON esistente e aggiungi la nuova connessione
    local temp=$(mktemp)
    jq --arg name "$name" \
       --arg identity_file "$identity_file" \
       --argjson port "$port" \
       --argjson uid "$(id -u)" \
       --argjson gid "$(id -g)" \
       --arg umask "022" \
       --arg user_host "$user_host" \
       --arg remote_path "$remote_path" \
       --arg local_path "$local_path" \
       '.[$name] = {identity_file: $identity_file, port: $port, uid: $uid, gid: $gid, umask: $umask, user_host: $user_host, remote_path: $remote_path, local_path: $local_path}' \
       "$config_file" > "$temp" && mv "$temp" "$config_file"
}

# Funzione per leggere le connessioni dal file JSON
read_connections() {
    local config_file="$HOME/.sshfs/config.json"
    if [[ -f "$config_file" ]]; then
        jq -r 'keys[]' "$config_file"
    fi
}

# Funzione per rimuovere una connessione
remove_connection() {
    local name=$1
    local config_file="$HOME/.sshfs/config.json"

    if [[ ! -f "$config_file" ]]; then
        echo -e "${RED}Nessuna configurazione trovata.${RESET}"
        exit 1
    fi

    if ! jq -e --arg name "$name" 'has($name)' "$config_file" > /dev/null; then
        echo -e "${RED}La connessione '$name' non esiste.${RESET}"
        exit 1
    fi

    local temp=$(mktemp)
    jq --arg name "$name" 'del(.[$name])' "$config_file" > "$temp" && mv "$temp" "$config_file"
    echo -e "${GREEN}Connessione '$name' rimossa con successo.${RESET}"
}

# Funzione per mostrare lo stato delle connessioni
show_status() {
    echo -e "${BOLD}Connessioni SSHFS attive:${RESET}"
    mount | grep "fuse.sshfs" | while read -r line; do
        echo -e "${BLUE}$line${RESET}"
    done
}

# Funzione per configurare il montaggio automatico
configure_auto_mount() {
    local name=$1
    local config_file="$HOME/.sshfs/config.json"

    if [[ ! -f "$config_file" ]]; then
        echo -e "${RED}Nessuna configurazione trovata.${RESET}"
        exit 1
    fi

    local connection_data=$(jq -r --arg name "$name" '.[$name]' "$config_file")
    if [[ "$connection_data" == "null" ]]; then
        echo -e "${RED}La connessione '$name' non esiste.${RESET}"
        exit 1
    fi

    # Estrai i dati della connessione
    local identity_file=$(echo "$connection_data" | jq -r '.identity_file')
    local port=$(echo "$connection_data" | jq -r '.port')
    local user_host=$(echo "$connection_data" | jq -r '.user_host')
    local remote_path=$(echo "$connection_data" | jq -r '.remote_path')
    local local_path=$(echo "$connection_data" | jq -r '.local_path')

    # Crea la riga per fstab
    local fstab_line="sshfs#$user_host:$remote_path $local_path fuse _netdev,IdentityFile=$identity_file,port=$port,allow_other,default_permissions 0 0"

    echo -e "${YELLOW}Vuoi aggiungere questa connessione al montaggio automatico?${RESET}"
    echo -e "${BLUE}$fstab_line${RESET}"
    echo -n "Confermi? (s/n): "
    read confirm

    if [[ "$confirm" == "s" ]]; then
        echo "$fstab_line" | sudo tee -a /etc/fstab > /dev/null
        echo -e "${GREEN}Configurazione del montaggio automatico completata.${RESET}"
    else
        echo -e "${YELLOW}Operazione annullata.${RESET}"
    fi
}

# Funzione per leggere input con validazione
read_input() {
    local prompt=$1
    local default=$2
    local validation=$3
    local value=""
    local valid=false

    while ! $valid; do
        echo -en "${YELLOW}$prompt${RESET}"
        [[ -n "$default" ]] && echo -en " [${GREEN}$default${RESET}]"
        echo -en ": "
        read value

        # Usa il valore predefinito se l'input è vuoto
        if [[ -z "$value" && -n "$default" ]]; then
            value="$default"
        fi

        # Valida l'input se è stata fornita una funzione di validazione
        if [[ -n "$validation" ]]; then
            if eval "$validation \"$value\""; then
                valid=true
            else
                echo -e "${RED}Input non valido. Riprova.${RESET}"
                continue
            fi
        else
            valid=true
        fi
    done

    echo "$value"
}

# Funzioni di validazione
validate_path() {
    [[ "$1" =~ ^/ ]]
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

validate_user_host() {
    [[ "$1" =~ ^[a-zA-Z0-9_.-]+@[a-zA-Z0-9_.-]+$ ]]
}

# Funzione per listare le connessioni
list_connections() {
    local config_file="$HOME/.sshfs/config.json"
    if [[ -f "$config_file" ]]; then
        echo -e "${BOLD}Connessioni configurate:${RESET}"
        jq -r 'keys[] as $k | "\($k): \(.[$k] | .user_host)"' "$config_file"
    else
        echo -e "${YELLOW}Nessuna connessione configurata.${RESET}"
    fi
}

# Verifica se ssh-agent è in esecuzione e avvialo se necessario
start_ssh_agent() {
    if [ -z "$SSH_AUTH_SOCK" ]; then
        echo -e "${YELLOW}Variabile SSH_AUTH_SOCK non impostata, avvio dell'agente...${RESET}"
        eval $(ssh-agent -s)
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}SSH agent avviato con successo${RESET}"
        else
            echo -e "${RED}Impossibile avviare l'agente SSH${RESET}"
            return 1
        fi
    elif ! pgrep -u "$USER" ssh-agent > /dev/null; then
        echo -e "${YELLOW}L'agente SSH non è in esecuzione. Avvio...${RESET}"
        eval $(ssh-agent -s)
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}SSH agent avviato con successo${RESET}"
        else
            echo -e "${RED}Impossibile avviare l'agente SSH${RESET}"
            return 1
        fi
    else
        echo -e "${BLUE}SSH agent già in esecuzione${RESET}"
    fi

    # Verifica che SSH_AUTH_SOCK sia ora impostato
    if [ -z "$SSH_AUTH_SOCK" ]; then
        echo -e "${RED}SSH_AUTH_SOCK ancora non impostato dopo l'avvio dell'agente${RESET}"
        return 1
    fi

    return 0
}

# Aggiungi la chiave all'agent
add_key_to_agent() {
    local key_file=$1

    # Verifica che l'agente sia in esecuzione
    if [ -z "$SSH_AUTH_SOCK" ]; then
        echo -e "${RED}SSH_AUTH_SOCK non impostato. Impossibile aggiungere la chiave.${RESET}"
        return 1
    fi

    # Verifica che il file della chiave esista
    if [ ! -f "$key_file" ]; then
        echo -e "${RED}Il file della chiave $key_file non esiste${RESET}"
        return 1
    fi

    echo -e "${YELLOW}Aggiunta della chiave all'SSH agent...${RESET}"
    ssh-add "$key_file"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Chiave aggiunta con successo all'agent${RESET}"
        return 0
    else
        echo -e "${RED}Errore nell'aggiunta della chiave all'agent${RESET}"
        echo -e "${YELLOW}Verifica che la chiave sia nel formato corretto e che la passphrase sia corretta${RESET}"
        return 1
    fi
}

# Funzione per configurare l'alias sshfs_connect
setup_alias() {
    local script_path="$(realpath "$0")"
    local alias_name="sshfs_connect"
    local bashrc="$HOME/.bashrc"

    echo -e "\n${BOLD}Configurazione dell'alias ${GREEN}$alias_name${RESET}${BOLD}...${RESET}"

    # Verifica se l'alias esiste già
    if grep -q "alias $alias_name=" "$bashrc"; then
        echo -e "${BLUE}L'alias $alias_name è già configurato nel tuo .bashrc${RESET}"
        return 0
    fi

    # Aggiungi l'alias al .bashrc
    echo -e "\n# Alias per SSHFS connection script" >> "$bashrc"
    echo "alias $alias_name=\"$script_path\"" >> "$bashrc"

    echo -e "${GREEN}Alias $alias_name configurato con successo!${RESET}"
    echo -e "${YELLOW}Per utilizzare l'alias nella sessione corrente, esegui:${RESET}"
    echo -e "${BOLD}source ~/.bashrc${RESET}"
    echo -e "${YELLOW}o riavvia il terminale.${RESET}"
}

# Funzione per smontare un filesystem SSHFS
unmount_sshfs() {
    local mount_point="$1"
    local force_unmount="$2"

    # Se force_unmount è true, usa sudo umount -l direttamente
    if [[ "$force_unmount" == "true" ]]; then
        echo -e "${YELLOW}Forzando lo smontaggio con sudo...${RESET}"
        sudo umount -l "$mount_point"
        return $?
    fi

    # Altrimenti, prova prima con fusermount
    echo -e "${YELLOW}Smontaggio della connessione esistente...${RESET}"
    fusermount -u "$mount_point"

    # Verifica se lo smontaggio è riuscito
    if [[ $? -ne 0 ]]; then
        # Controlla se il problema è "Device or resource busy"
        if mountpoint -q "$mount_point"; then
            echo -e "${RED}Impossibile smontare: filesystem occupato${RESET}"

            # Mostra i processi che stanno usando il filesystem
            echo -e "${YELLOW}Processi che stanno usando il filesystem:${RESET}"
            lsof "$mount_point" 2>/dev/null | head -n 10

            # Chiedi all'utente se vuole forzare lo smontaggio
            echo -en "${YELLOW}Vuoi forzare lo smontaggio con sudo? (s/n)${RESET}: "
            read force

            if [[ "$force" == "s" ]]; then
                echo -e "${YELLOW}Forzando lo smontaggio con sudo...${RESET}"
                sudo umount -l "$mount_point"
                if [[ $? -eq 0 ]]; then
                    echo -e "${GREEN}Filesystem smontato con successo${RESET}"
                    return 0
                else
                    echo -e "${RED}Errore: impossibile forzare lo smontaggio${RESET}"
                    return 1
                fi
            else
                echo -e "${YELLOW}Operazione di smontaggio annullata${RESET}"
                return 1
            fi
        else
            # Altro errore non relativo a "Device busy"
            echo -e "${RED}Errore durante lo smontaggio: $(fusermount -u "$mount_point" 2>&1)${RESET}"
            return 1
        fi
    fi

    echo -e "${GREEN}Connessione esistente smontata con successo${RESET}"
    return 0
}

# Funzione per connettersi via SSH a una connessione esistente
ssh_connect() {
    local name=$1
    local config_file="$HOME/.sshfs/config.json"

    if [[ ! -f "$config_file" ]]; then
        echo -e "${RED}Nessuna configurazione trovata.${RESET}"
        exit 1
    fi

    local connection_data=$(jq -r --arg name "$name" '.[$name]' "$config_file")
    if [[ "$connection_data" == "null" ]]; then
        echo -e "${RED}La connessione '$name' non esiste.${RESET}"
        exit 1
    fi

    # Estrai i dati della connessione
    local identity_file=$(echo "$connection_data" | jq -r '.identity_file')
    local port=$(echo "$connection_data" | jq -r '.port')
    local user_host=$(echo "$connection_data" | jq -r '.user_host')
    local remote_path=$(echo "$connection_data" | jq -r '.remote_path')

    # Verifica la chiave SSH
    if [[ ! -f "$identity_file" ]]; then
        echo -e "${RED}Chiave SSH non trovata: $identity_file${RESET}"
        exit 1
    fi

    # Prepara l'agente SSH
    echo -e "\n${BOLD}Preparazione dell'agente SSH...${RESET}"
    if ! start_ssh_agent; then
        echo -e "${RED}Impossibile avviare l'agente SSH. Provo a continuare comunque...${RESET}"
    fi

    if ! add_key_to_agent "$identity_file"; then
        echo -e "${YELLOW}Avviso: Impossibile aggiungere la chiave all'agente SSH.${RESET}"
        echo -e "${YELLOW}Provo a continuare la connessione SSH senza l'agente SSH...${RESET}"
    fi

    # Avvio della connessione SSH
    echo -e "\n${BOLD}Avvio connessione SSH a $user_host...${RESET}"
    echo -e "${YELLOW}Directory remota: $remote_path${RESET}"
    ssh -A -t -i "$identity_file" -p "$port" "$user_host" "cd \"$remote_path\" && bash -l"

    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Errore durante la connessione SSH${RESET}"
        exit 1
    fi

    echo -e "${GREEN}Connessione SSH chiusa${RESET}"
}

# Gestione degli argomenti da riga di comando
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -l|--list)
            list_connections
            exit 0
            ;;
        -a|--add)
            add_new=true
            shift
            ;;
        -r|--remove)
            if [[ -n $2 ]]; then
                remove_connection "$2"
                exit 0
            else
                echo -e "${RED}Errore: nome connessione mancante per --remove${RESET}"
                exit 1
            fi
            ;;
        -s|--status)
            show_status
            exit 0
            ;;
        --auto-mount)
            if [[ -n $2 ]]; then
                configure_auto_mount "$2"
                exit 0
            else
                echo -e "${RED}Errore: nome connessione mancante per --auto-mount${RESET}"
                exit 1
            fi
            ;;
        --setup-alias)
            setup_alias
            exit 0
            ;;
        --ssh)
            if [[ -n $2 ]]; then
                ssh_connect "$2"
                exit 0
            else
                echo -e "${RED}Errore: nome connessione mancante per --ssh${RESET}"
                exit 1
            fi
            ;;
        *)
            connection_name=$1
            shift
            ;;
    esac
done

# Verifica le dipendenze all'avvio
check_dependencies

# Miglioramento della visualizzazione delle connessioni
if [[ "$add_new" == "true" ]]; then
    echo -e "\n${BOLD}Aggiunta di una nuova connessione${RESET}"

    # Nome della connessione
    name=""
    while [[ -z "$name" ]]; do
        echo -en "${YELLOW}Nome della connessione${RESET}: "
        read name
        if [[ -z "$name" ]]; then
            echo -e "${RED}Il nome della connessione non può essere vuoto${RESET}"
        fi
    done

    # File di identità
    default_identity="$HOME/.ssh/id_rsa"
    while true; do
        echo -en "${YELLOW}File di identità SSH${RESET}"
        [[ -n "$default_identity" ]] && echo -en " [${GREEN}$default_identity${RESET}]"
        echo -en ": "
        read identity_file

        # Usa il valore predefinito se l'input è vuoto
        if [[ -z "$identity_file" && -n "$default_identity" ]]; then
            identity_file="$default_identity"
        fi

        # Valida il percorso
        if [[ "$identity_file" =~ ^/ ]]; then
            if [[ -f "$identity_file" ]]; then
                break
            else
                echo -e "${RED}Il file $identity_file non esiste${RESET}"
                echo -e "${YELLOW}File SSH disponibili:${RESET}"
                ls -l "$HOME/.ssh/"
            fi
        else
            echo -e "${RED}Inserisci un percorso assoluto (che inizia con /)${RESET}"
        fi
    done

    # Porta SSH
    echo -en "${YELLOW}Porta SSH${RESET} [${GREEN}22${RESET}]: "
    read port
    if [[ -z "$port" ]]; then
        port="22"
    elif ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "${RED}Porta non valida. Utilizzo porta 22.${RESET}"
        port="22"
    fi

    # Utente e host
    while true; do
        echo -en "${YELLOW}Utente e host (formato: user@host)${RESET}: "
        read user_host
        if [[ "$user_host" =~ ^[a-zA-Z0-9_.-]+@[a-zA-Z0-9_.-]+$ ]]; then
            break
        else
            echo -e "${RED}Formato non valido. Usa il formato user@host${RESET}"
        fi
    done

    # Percorso remoto
    default_remote_path="/home/$(echo "$user_host" | cut -d@ -f1)"
    echo -en "${YELLOW}Percorso remoto${RESET} [${GREEN}$default_remote_path${RESET}]: "
    read remote_path
    if [[ -z "$remote_path" ]]; then
        remote_path="$default_remote_path"
    elif ! [[ "$remote_path" =~ ^/ ]]; then
        echo -e "${YELLOW}Hai inserito un percorso relativo: $remote_path${RESET}"
    fi

    # Percorso locale
    default_local_path="$HOME/RemoteDirectory/${name}"
    echo -en "${YELLOW}Percorso locale${RESET} [${GREEN}$default_local_path${RESET}]: "
    read local_path
    if [[ -z "$local_path" ]]; then
        local_path="$default_local_path"
    elif ! [[ "$local_path" =~ ^/ ]]; then
        echo -e "${YELLOW}Hai inserito un percorso relativo, verrà convertito in assoluto: $HOME/RemoteDirectory/${local_path}${RESET}"
        local_path="$HOME/RemoteDirectory/${local_path}"
    fi

    # Conferma dei dati inseriti
    echo -e "\n${BOLD}Riepilogo della connessione:${RESET}"
    echo -e "Nome: ${BLUE}$name${RESET}"
    echo -e "File di identità: ${BLUE}$identity_file${RESET}"
    echo -e "Porta: ${BLUE}$port${RESET}"
    echo -e "Utente e host: ${BLUE}$user_host${RESET}"
    echo -e "Percorso remoto: ${BLUE}$remote_path${RESET}"
    echo -e "Percorso locale: ${BLUE}$local_path${RESET}"

    echo -en "\n${YELLOW}Confermi i dati inseriti? (s/n)${RESET}: "
    read confirm
    if [[ "$confirm" == "s" ]]; then
        add_connection "$name" "$identity_file" "$port" "$user_host" "$remote_path" "$local_path"
        echo -e "${GREEN}Connessione '$name' aggiunta con successo${RESET}"
    else
        echo -e "${YELLOW}Vuoi reinserire i dati? (s/n)${RESET}: "
        read retry
        if [[ "$retry" == "s" ]]; then
            # Riavvia il processo di aggiunta
            exec "$0" -a
        else
            echo -e "${YELLOW}Operazione annullata${RESET}"
            exit 0
        fi
    fi
    exit 0
else
    echo -e "\n${BOLD}Connessioni disponibili:${RESET}"
    echo -e "${GREEN}add${RESET} - Aggiungi una nuova connessione"
    for key in $(read_connections); do
        echo -e "${BLUE}$key${RESET}"
    done
fi

# Stampa delle opzioni
echo -e "\n\e[1mSeleziona la connessione o digita 'add' per aggiungere una nuova connessione:\e[0m"
for key in $(read_connections); do
    if [[ "$key" == "add" ]]; then
        echo -e "\e[32m$key\e[0m"
    else
        echo -e "\e[36m$key\e[0m"
    fi
done

# Lettura della scelta
read choice

# Controllo se l'utente vuole aggiungere una nuova connessione
if [[ "$choice" == "add" ]]; then
    echo -e "\n${BOLD}Aggiunta di una nuova connessione${RESET}"

    # Nome della connessione
    name=""
    while [[ -z "$name" ]]; do
        echo -en "${YELLOW}Nome della connessione${RESET}: "
        read name
        if [[ -z "$name" ]]; then
            echo -e "${RED}Il nome della connessione non può essere vuoto${RESET}"
        fi
    done

    # File di identità
    default_identity="$HOME/.ssh/id_rsa"
    while true; do
        echo -en "${YELLOW}File di identità SSH${RESET}"
        [[ -n "$default_identity" ]] && echo -en " [${GREEN}$default_identity${RESET}]"
        echo -en ": "
        read identity_file

        # Usa il valore predefinito se l'input è vuoto
        if [[ -z "$identity_file" && -n "$default_identity" ]]; then
            identity_file="$default_identity"
        fi

        # Valida il percorso
        if [[ "$identity_file" =~ ^/ ]]; then
            if [[ -f "$identity_file" ]]; then
                break
            else
                echo -e "${RED}Il file $identity_file non esiste${RESET}"
                echo -e "${YELLOW}File SSH disponibili:${RESET}"
                ls -l "$HOME/.ssh/"
            fi
        else
            echo -e "${RED}Inserisci un percorso assoluto (che inizia con /)${RESET}"
        fi
    done

    # Porta SSH
    echo -en "${YELLOW}Porta SSH${RESET} [${GREEN}22${RESET}]: "
    read port
    if [[ -z "$port" ]]; then
        port="22"
    elif ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "${RED}Porta non valida. Utilizzo porta 22.${RESET}"
        port="22"
    fi

    # Utente e host
    while true; do
        echo -en "${YELLOW}Utente e host (formato: user@host)${RESET}: "
        read user_host
        if [[ "$user_host" =~ ^[a-zA-Z0-9_.-]+@[a-zA-Z0-9_.-]+$ ]]; then
            break
        else
            echo -e "${RED}Formato non valido. Usa il formato user@host${RESET}"
        fi
    done

    # Percorso remoto
    default_remote_path="/home/$(echo "$user_host" | cut -d@ -f1)"
    echo -en "${YELLOW}Percorso remoto${RESET} [${GREEN}$default_remote_path${RESET}]: "
    read remote_path
    if [[ -z "$remote_path" ]]; then
        remote_path="$default_remote_path"
    elif ! [[ "$remote_path" =~ ^/ ]]; then
        echo -e "${YELLOW}Hai inserito un percorso relativo: $remote_path${RESET}"
    fi

    # Percorso locale
    default_local_path="$HOME/RemoteDirectory/${name}"
    echo -en "${YELLOW}Percorso locale${RESET} [${GREEN}$default_local_path${RESET}]: "
    read local_path
    if [[ -z "$local_path" ]]; then
        local_path="$default_local_path"
    elif ! [[ "$local_path" =~ ^/ ]]; then
        echo -e "${YELLOW}Hai inserito un percorso relativo, verrà convertito in assoluto: $HOME/RemoteDirectory/${local_path}${RESET}"
        local_path="$HOME/RemoteDirectory/${local_path}"
    fi

    # Conferma dei dati inseriti
    echo -e "\n${BOLD}Riepilogo della connessione:${RESET}"
    echo -e "Nome: ${BLUE}$name${RESET}"
    echo -e "File di identità: ${BLUE}$identity_file${RESET}"
    echo -e "Porta: ${BLUE}$port${RESET}"
    echo -e "Utente e host: ${BLUE}$user_host${RESET}"
    echo -e "Percorso remoto: ${BLUE}$remote_path${RESET}"
    echo -e "Percorso locale: ${BLUE}$local_path${RESET}"

    echo -en "\n${YELLOW}Confermi i dati inseriti? (s/n)${RESET}: "
    read confirm
    if [[ "$confirm" == "s" ]]; then
        add_connection "$name" "$identity_file" "$port" "$user_host" "$remote_path" "$local_path"
        echo -e "${GREEN}Connessione '$name' aggiunta con successo${RESET}"
    else
        echo -e "${YELLOW}Vuoi reinserire i dati? (s/n)${RESET}: "
        read retry
        if [[ "$retry" == "s" ]]; then
            # Riavvia il processo di aggiunta
            exec "$0" -a
        else
            echo -e "${YELLOW}Operazione annullata${RESET}"
            exit 0
        fi
    fi
    exit 0
fi

# Controllo se la scelta è valida
connection=$(jq -r --arg choice "$choice" '.[$choice]' "$HOME/.sshfs/config.json")
if [[ "$connection" == "null" ]]; then
    echo "Scelta non valida."
    exit 1
fi

# Mostra i dati della connessione selezionata per conferma
echo -e "${BOLD}Connessione selezionata:${RESET}"
jq -r --arg choice "$choice" '.[$choice] | "Nome: \(.identity_file)\nFile di identità: \(.identity_file)\nPorta: \(.port)\nUtente e host: \(.user_host)\nPercorso remoto: \(.remote_path)\nPercorso locale: \(.local_path)"' "$HOME/.sshfs/config.json"

# Mostra opzioni aggiuntive disponibili
echo -e "\n${BOLD}Opzioni disponibili:${RESET}"
echo -e "1. Connetti con SSHFS (percorso locale → remoto)"
echo -e "2. Connetti direttamente con SSH (terminale remoto)"
echo -e "3. Annulla"

echo -en "\n${YELLOW}Scegli un'opzione (1-3):${RESET} "
read option

if [[ "$option" == "2" ]]; then
    # Avvia direttamente SSH
    ssh_connect "$choice"
    exit 0
elif [[ "$option" == "3" ]]; then
    echo -e "${YELLOW}Operazione annullata.${RESET}"
    exit 0
elif [[ "$option" != "1" ]]; then
    echo -e "${YELLOW}Opzione non valida, procedo con la connessione SSHFS (opzione 1).${RESET}"
fi

# Conferma della connessione
echo -en "\n${YELLOW}Confermi la connessione SSHFS? (s/n)${RESET}: "
read confirm

if [[ "$confirm" != "s" ]]; then
    echo -e "${YELLOW}Connessione annullata.${RESET}"
    exit 0
fi

echo -e "${GREEN}Procedo con la connessione...${RESET}"

# Verifica se la chiave SSH indicata esiste
identity_file=$(jq -r --arg choice "$choice" '.[$choice].identity_file' "$HOME/.sshfs/config.json")
if [[ ! -f "$identity_file" ]]; then
    echo -e "${RED}Chiave SSH non trovata: $identity_file${RESET}"
    exit 1
fi

# Verifica e creazione della cartella locale, se necessario
local_path=$(jq -r --arg choice "$choice" '.[$choice].local_path' "$HOME/.sshfs/config.json")
if [[ ! -d "$local_path" ]]; then
    echo -e "${YELLOW}Creazione della cartella locale $local_path...${RESET}"
    mkdir -p "$local_path"
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Errore: impossibile creare la cartella locale${RESET}"
        exit 1
    fi
    echo -e "${GREEN}Cartella locale creata con successo${RESET}"
fi

# Smontaggio di eventuale connessione corrente alla stessa cartella locale
if mountpoint -q "$local_path"; then
    # Usa la nuova funzione invece della semplice chiamata a fusermount
    if ! unmount_sshfs "$local_path" "false"; then
        echo -e "${YELLOW}Vuoi continuare comunque? (s/n)${RESET}: "
        read continue_anyway
        if [[ "$continue_anyway" != "s" ]]; then
            echo -e "${YELLOW}Connessione annullata${RESET}"
            exit 0
        fi
        echo -e "${YELLOW}Tentativo di continuare senza smontare...${RESET}"
    fi
else
    echo -e "${BLUE}Nessuna connessione attiva alla cartella locale '$local_path'${RESET}"
fi

# Verifica che la directory sia vuota prima del montaggio
if [ -z "$(ls -A $local_path)" ]; then
    echo -e "${GREEN}La cartella locale è vuota, procedo con il montaggio${RESET}"
else
    echo -e "${YELLOW}La cartella locale non è vuota. Vuoi continuare? (s/n)${RESET}: "
    read confirm
    if [[ "$confirm" != "s" ]]; then
        echo -e "${YELLOW}Connessione annullata${RESET}"
        exit 0
    fi
fi

# Prima di avviare la connessione SSHFS
echo -e "\n${BOLD}Preparazione dell'agente SSH...${RESET}"
if ! start_ssh_agent; then
    echo -e "${RED}Impossibile avviare l'agente SSH. Provo a continuare comunque...${RESET}"
fi

if ! add_key_to_agent "$identity_file"; then
    echo -e "${YELLOW}Avviso: Impossibile aggiungere la chiave all'agente SSH.${RESET}"
    echo -e "${YELLOW}Provo a continuare la connessione SSHFS senza l'agente SSH...${RESET}"
fi

# Avvio della connessione SSHFS
echo -e "\n${BOLD}Avvio della connessione SSHFS...${RESET}"

# Dati della connessione
port=$(jq -r --arg choice "$choice" '.[$choice].port' "$HOME/.sshfs/config.json")
user_host=$(jq -r --arg choice "$choice" '.[$choice].user_host' "$HOME/.sshfs/config.json")
remote_path=$(jq -r --arg choice "$choice" '.[$choice].remote_path' "$HOME/.sshfs/config.json")
uid=$(id -u)
gid=$(id -g)
umask="022"

# Verifico la connessione SSH prima di tentare il montaggio
echo -e "${YELLOW}Verifico la connessione SSH...${RESET}"
ssh -o "BatchMode=yes" -o "StrictHostKeyChecking=accept-new" -i "$identity_file" -p "$port" "$user_host" "echo 'Connessione SSH stabilita con successo'" &> /dev/null

if [ $? -eq 0 ]; then
    echo -e "${GREEN}Connessione SSH testata con successo${RESET}"
    # Montaggio della cartella remota
    echo -e "${YELLOW}Montaggio in corso...${RESET}"
    sshfs -o IdentityFile="$identity_file",port="$port",uid="$uid",gid="$gid",umask="$umask",reconnect,ServerAliveInterval=15,ServerAliveCountMax=3 "$user_host:$remote_path" "$local_path"

    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}Connessione SSHFS stabilita con successo${RESET}"
        echo -e "\n${BOLD}Contenuto della cartella montata:${RESET}"
        ls -l "$local_path"

        # Chiedi all'utente se vuole avviare anche una connessione SSH
        echo -en "\n${YELLOW}Vuoi avviare una connessione SSH? (s/n)${RESET}: "
        read confirm

        if [[ "$confirm" == "s" ]]; then
            echo -e "${BLUE}Avvio connessione SSH...${RESET}"
            # Usa -A per inoltrare l'agent SSH e -t per allocare un terminale
            # e cd per andare direttamente nella directory remota
            ssh -A -t -i "$identity_file" -p "$port" "$user_host" "cd \"$remote_path\" && bash -l"
            if [[ $? -ne 0 ]]; then
                echo -e "${RED}Errore durante la connessione SSH${RESET}"
                exit 1
            fi
            echo -e "${GREEN}Connessione SSH chiusa${RESET}"
        fi

        # Aggiungi suggerimento per la connessione SSH in qualsiasi momento
        echo -e "\n${BOLD}Suggerimento:${RESET} Per aprire una connessione SSH a questa destinazione in qualsiasi momento, esegui:"
        echo -e "${BOLD}$0 --ssh \"$choice\"${RESET}"
        echo -e "o se hai configurato l'alias:"
        echo -e "${BOLD}sshfs_connect --ssh \"$choice\"${RESET}"
    else
        echo -e "${RED}Errore durante la connessione SSHFS${RESET}"
        echo -e "${YELLOW}Verifica che la chiave SSH sia valida e che l'host remoto sia raggiungibile${RESET}"
        exit 1
    fi
else
    echo -e "${RED}Impossibile stabilire una connessione SSH${RESET}"
    echo -e "${YELLOW}Verifico che la chiave SSH sia nel formato corretto...${RESET}"

    # Controlla il formato della chiave
    ssh-keygen -l -f "$identity_file" &> /dev/null
    if [ $? -ne 0 ]; then
        echo -e "${RED}Il file della chiave non sembra essere in un formato valido${RESET}"
        echo -e "${YELLOW}Prova a convertire la chiave o a generarne una nuova${RESET}"
    else
        echo -e "${GREEN}Il formato della chiave sembra corretto${RESET}"
        echo -e "${YELLOW}Verifica la connettività di rete e che l'host remoto sia corretto${RESET}"
    fi
    exit 1
fi

# Aggiungi la configurazione dell'alias
setup_alias

# Messaggio finale per ricordare all'utente di eseguire source ~/.bashrc
echo -e "\n${BOLD}${YELLOW}IMPORTANTE:${RESET} Per utilizzare il comando ${GREEN}sshfs_connect${RESET} in questa sessione, esegui:${RESET}"
echo -e "${BOLD}source ~/.bashrc${RESET}"

exit 0
