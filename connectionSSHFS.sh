#!/bin/bash

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
    echo "Inserisci i dettagli della nuova connessione:"
    echo -n "Nome: "
    read name
    echo -n "File di identità: "
    read identity_file
    # Assicurati che la sintassi del file di identità sia corretta
    if [[ ! "$identity_file" =~ ^/ ]]; then
        echo "Il percorso del file di identità deve iniziare con '/'."
        exit 1
    fi
    echo -n "Porta: "
    read port
    echo -n "Utente e host: "
    read user_host
    echo -n "Percorso remoto: "
    read remote_path
    # Assicurati che la sintaassi del percorso remoto sia corretta
    while [[ ! "$remote_path" =~ ^/ ]]; do
        echo "Il percorso remoto deve iniziare con '/'."
        echo -n "Percorso remoto: "
        read remote_path
    done
    echo -n "Percorso locale: "
    read local_path
    # Assicurati che la sintassi del percorso locale sia corretta
    while [[ ! "$local_path" =~ ^/ ]]; do
        echo "Il percorso locale deve iniziare con '/'."
        echo -n "Percorso locale: "
        read local_path
    done
    add_connection "$name" "$identity_file" "$port" "$user_host" "$remote_path" "$local_path"
    echo "Connessione '$name' aggiunta con successo."
    exit 0
fi

# Controllo se la scelta è valida
connection=$(jq -r --arg choice "$choice" '.[$choice]' "$HOME/.sshfs/config.json")
if [[ "$connection" == "null" ]]; then
    echo "Scelta non valida."
    exit 1
fi

# Mostra i dati della connessione selezionata per conferma
echo "Connessione selezionata:"
jq -r --arg choice "$choice" '.[$choice] | "Nome: \(.identity_file)\nFile di identità: \(.identity_file)\nPorta: \(.port)\nUtente e host: \(.user_host)\nPercorso remoto: \(.remote_path)\nPercorso locale: \(.local_path)"' "$HOME/.sshfs/config.json"

# Conferma della connessione
echo -e "\n\e[1;33mConfermi la connessione SSHFS? (s/n)\e[0m"

read confirm

if [[ "$confirm" != "s" ]]; then
    echo "Connessione annullata."
    exit 0
fi

# Verifica se la chiave SSH indicata esiste
identity_file=$(jq -r --arg choice "$choice" '.[$choice].identity_file' "$HOME/.sshfs/config.json")
if [[ ! -f "$identity_file" ]]; then
    echo "Chiave SSH non trovata."
    exit 1
fi

# Verifica e creazione della cartella locale, se necessario
local_path=$(jq -r --arg choice "$choice" '.[$choice].local_path' "$HOME/.sshfs/config.json")
if [[ ! -d "$local_path" ]]; then
    sudo mkdir -p "$local_path"
    sudo chown giuseppe:giuseppe "$local_path"
    sudo chmod 755 "$local_path"
fi
# Smontaggio di eventuale connessione corrente alla stessa cartella locale
if mountpoint -q "$local_path"; then
    fusermount -u "$local_path"
    if mountpoint -q "$local_path"; then
        echo "Impossibile smontare la cartella locale."
        exit 1
    fi
else
    echo "Nessuna connessione attiva alla cartella locale '$local_path'."
fi

# Verifica che la directory sia vuota prima del montaggio
if [ -z "$(ls -A $local_path)" ]; then
    echo "La cartella locale è vuota."
else
    echo "La cartella locale non è vuota. Vuoi continuare? (s/n)"
    read confirm
    if [[ "$confirm" != "s" ]]; then
        echo "Connessione annullata."
        exit 0
    fi
fi

# Avvio della connessione SSHFS
# Dati della connessione
port=$(jq -r --arg choice "$choice" '.[$choice].port' "$HOME/.sshfs/config.json")
user_host=$(jq -r --arg choice "$choice" '.[$choice].user_host' "$HOME/.sshfs/config.json")
remote_path=$(jq -r --arg choice "$choice" '.[$choice].remote_path' "$HOME/.sshfs/config.json")
uid=$(id -u)
gid=$(id -g)
umask="022"

# Montaggio della cartella remota
sshfs -o IdentityFile="$identity_file",port="$port",uid="$uid",gid="$gid",umask="$umask" "$user_host:$remote_path" "$local_path"

if [[ $? -eq 0 ]]; then
    echo "Connessione riuscita."
    # Lista i file montati
    ls -l "$local_path"
else
    echo "Errore durante la connessione."
    exit 1
fi

# Chiedi all'utente se vuole avviare anche una connessione SSH
echo -e "\n\e[1;33mVuoi avviare una connessione SSH? (s/n)\e[0m"
read confirm

if [[ "$confirm" == "s" ]]; then
    ssh -i "$identity_file" -p "$port" "$user_host"
    if [[ $? -ne 0 ]]; then
        echo "Errore durante la connessione SSH."
        exit 1
    fi
    echo "Connessione SSH chiusa."
fi

exit 0