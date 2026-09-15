# Shared by the developer installer and embedded in the team installer.
fetch_model() {
    local url="$1" destination="$2" expected="$3" actual
    if [ -f "$destination" ]; then
        actual="$(shasum -a 256 "$destination" | awk '{print $1}')"
        if [ "$actual" = "$expected" ]; then
            echo "Modell klar: $(basename "$destination")"
            return
        fi
        echo "Modellfilen har feil kontrollsum: $destination" >&2
        echo "Flytt eller slett filen og kjør installasjonen igjen." >&2
        return 1
    fi
    if [ -f "$destination.download" ]; then
        actual="$(shasum -a 256 "$destination.download" | awk '{print $1}')"
        if [ "$actual" = "$expected" ]; then
            mv "$destination.download" "$destination"
            return
        fi
    fi
    echo "Laster ned $(basename "$destination") …"
    # Keep partial downloads so the same command resumes an interrupted install.
    curl --fail --location --proto '=https' --tlsv1.2 --retry 3 \
        --connect-timeout 20 --continue-at - "$url" -o "$destination.download"
    actual="$(shasum -a 256 "$destination.download" | awk '{print $1}')"
    if [ "$actual" != "$expected" ]; then
        rm -f "$destination.download"
        echo "Feil kontrollsum for $(basename "$destination"). Kjør installasjonen igjen." >&2
        return 1
    fi
    mv "$destination.download" "$destination"
}

download_models() {
    local model_dir="${DIKTAT_MODEL_DIR:-$HOME/Library/Application Support/Diktat/Models}"
    mkdir -p "$model_dir"
    fetch_model \
        'https://huggingface.co/NbAiLab/nb-whisper-medium/resolve/0ed074d5985bd56ca4140159a9dbffbc3fb5117e/ggml-model.bin' \
        "$model_dir/nb-whisper-medium.bin" \
        f73141401d203ee77fc7ddf7bf97926a8a85fe85faa6066a6920e4815f48a73d
    fetch_model \
        'https://huggingface.co/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v6.2.0.bin' \
        "$model_dir/silero-v6.2.0.bin" \
        2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987
}
