#!/usr/bin/env bash
# Helpers sourced by the entry script.

current_day_of_week() {
	printf '%(%u)T\n' -1
}

current_hour_24() {
	printf '%(%H)T\n' -1
}

current_day_name() {
	printf '%(%A)T\n' -1
}

# Function to check if current day is a weekday (after 4PM Friday until midnight Sunday)
function is_weekday() {
	local day_of_week
	day_of_week=$(current_day_of_week) # %u gives 1-7 (Monday is 1, Sunday is 7)
	local hour
	hour=$(current_hour_24) # %H gives hour in 24-hour format (00-23)

	# Monday through Thursday are always weekdays
	if [[ $day_of_week -ge 1 && $day_of_week -le 4 ]]; then
		return 0 # Is weekday
	# Friday before 4PM is weekday, after 4PM is weekend
	elif [[ $day_of_week -eq 5 ]]; then
		if [[ $hour -lt 14 ]]; then
			return 0 # Is weekday (Friday before 4PM)
		else
			return 1 # Is weekend (Friday after 4PM)
		fi
	# Saturday and Sunday are weekend
	else
		return 1 # Is weekend
	fi
}

# Unified word unscrambling challenge function
# Args: challenge_name word_length words_count timeout_seconds initial_delay_max post_delay_min post_delay_range
function run_word_challenge() {
	local challenge_name="$1"
	local word_length="$2"
	local words_count="$3"
	local timeout_seconds="$4"
	local initial_delay_max="${5:-20}"
	local post_delay_min="${6:-0}"
	local post_delay_range="${7:-20}"

	echo -e "${YELLOW}${challenge_name} challenge will begin shortly...${NC}"

	# Initial delay
	local sleep_duration=$((RANDOM % initial_delay_max))
	sleep "$sleep_duration"

	# Load words file
	local script_dir words_file
	script_dir="$(dirname "$(readlink -f "$0")")"
	words_file="$script_dir/words.txt"

	if [[ ! -f $words_file ]]; then
		echo -e "${RED}Error: words.txt file not found at $words_file${NC}"
		return 1
	fi

	echo -e "${CYAN}Challenge: Words with ${word_length} letters${NC}"

	# Load random words of specified length
	local -a selected_words
	mapfile -t selected_words < <(grep -E "^[a-zA-Z]{$word_length}$" "$words_file" | shuf -n "$words_count")

	if [[ ${#selected_words[@]} -lt $words_count ]]; then
		echo -e "${RED}Warning: Could only find ${#selected_words[@]} words of length $word_length.${NC}"
		words_count=${#selected_words[@]}
		if [[ $words_count -eq 0 ]]; then
			echo -e "${RED}Error: No words of length $word_length found in $words_file${NC}"
			return 1
		fi
	fi

	# Convert to uppercase
	for i in "${!selected_words[@]}"; do
		selected_words[i]=$(echo "${selected_words[i]}" | tr '[:lower:]' '[:upper:]')
	done

	echo -e "${CYAN}Here are ${words_count} random words. Remember them:${NC}"

	# Display words in grid
	for ((i = 0; i < words_count; i++)); do
		printf "${BLUE}%-15s${NC}" "${selected_words[i]}"
		if (((i + 1) % 4 == 0)); then
			echo ""
		fi
	done

	# Select and scramble a word
	local target_index target_word scrambled_word
	target_index=$((RANDOM % words_count))
	target_word="${selected_words[target_index]}"
	scrambled_word=$(echo "$target_word" | fold -w1 | shuf | tr -d '\n')

	if [[ $scrambled_word == "$target_word" ]]; then
		scrambled_word=$(echo "$target_word" | rev)
	fi

	echo -e "\n${YELLOW}One of those words has been scrambled to:${NC} ${CYAN}$scrambled_word${NC}"
	echo -e "${YELLOW}Unscramble the word to proceed (you have $timeout_seconds seconds):${NC}"

	# Timer display background process
	(
		local start_time current_time elapsed remaining
		start_time=$(current_epoch)
		while true; do
			current_time=$(current_epoch)
			elapsed=$((current_time - start_time))
			remaining=$((timeout_seconds - elapsed))
			if [[ $remaining -le 0 ]]; then
				echo -ne "\r${YELLOW}Time remaining: 0 seconds${NC}    "
				break
			fi
			echo -ne "\r${YELLOW}Time remaining: ${remaining} seconds${NC}    "
			sleep 1
		done
	) &
	local display_pid=$!

	# Read input with timeout
	local user_input read_status
	read -t "$timeout_seconds" -r user_input
	read_status=$?

	kill "$display_pid" 2>/dev/null
	wait "$display_pid" 2>/dev/null
	echo

	if [[ $read_status -ne 0 ]]; then
		echo -e "${RED}Time's up! Challenge failed. The correct word was '$target_word'.${NC}"
		return 1
	fi

	user_input=$(echo "$user_input" | tr '[:lower:]' '[:upper:]' | xargs)

	if [[ $user_input == "$target_word" ]]; then
		echo -e "${GREEN}Correct! Proceeding with installation...${NC}"
		local post_challenge_sleep=$((RANDOM % post_delay_range + post_delay_min))
		[[ $post_challenge_sleep -gt 0 ]] && sleep "$post_challenge_sleep"
		return 0
	else
		echo -e "${RED}Incorrect answer. Installation aborted. The correct word was '$target_word'.${NC}"
		return 1
	fi
}

# Function to prompt for solving a word unscrambling challenge (only for steam)
function prompt_for_steam_challenge() {
	echo -e "${YELLOW}WARNING: You are trying to install Steam.${NC}"

	# Check if it's a weekday and block completely
	if is_weekday; then
		local day_name
		day_name=$(current_day_name)
		echo -e "${RED}Steam installation BLOCKED: Steam cannot be installed on weekdays.${NC}"
		echo -e "${RED}Today is $day_name. Please try again on the weekend (Saturday or Sunday).${NC}"
		return 1
	fi

	# word_length=5, words_count=160, timeout=60s, initial_delay=20, post_delay=0-20
	run_word_challenge "Weekend Steam" 5 160 60 20 0 20
}

# Function to prompt for solving a word unscrambling challenge (for greylisted packages - always active)
function prompt_for_greylist_challenge() {
	echo -e "${YELLOW}WARNING: You are trying to install a greylisted package.${NC}"

	# word_length=6, words_count=120, timeout=90s, initial_delay=30, post_delay=15-35
	run_word_challenge "Greylist" 6 120 90 30 15 20
}
