#!/bin/bash

# The actual program name
declare -r myname="minecraftd"
declare -r game="minecraft"

# General rule for the variable-naming-schema:
# Variables in capital letters may be passed through the command line others not.
# Avoid altering any of those later in the code since they may be readonly (IDLE_SERVER is an exception!)

# You may use this script for any game server of your choice, just alter the config file
[[ -n "${SERVER_ROOT}" ]]  && declare -r SERVER_ROOT=${SERVER_ROOT}   || SERVER_ROOT="/srv/${game}"
[[ -n "${BACKUP_DEST}" ]]  && declare -r BACKUP_DEST=${BACKUP_DEST}   || BACKUP_DEST="/srv/${game}/backup"
[[ -n "${BACKUP_PATHS}" ]] && declare -r BACKUP_PATHS=${BACKUP_PATHS} || BACKUP_PATHS="world"
[[ -n "${BACKUP_FLAGS}" ]] && declare -r BACKUP_FLAGS=${BACKUP_FLAGS} || BACKUP_FLAGS="-z"
[[ -n "${KEEP_BACKUPS}" ]] && declare -r KEEP_BACKUPS=${KEEP_BACKUPS} || KEEP_BACKUPS="10"
[[ -n "${GAME_USER}" ]]    && declare -r GAME_USER=${GAME_USER}       || GAME_USER="minecraft"
[[ -n "${MAIN_EXECUTABLE}" ]] && declare -r MAIN_EXECUTABLE=${MAIN_EXECUTABLE} || MAIN_EXECUTABLE="minecraft_server.jar"
[[ -n "${SESSION_NAME}" ]] && declare -r SESSION_NAME=${SESSION_NAME} || SESSION_NAME="${game}"

# Command and parameter declaration with which to start the server
[[ -n "${SERVER_START_CMD}" ]] && declare -r SERVER_START_CMD=${SERVER_START_CMD} || SERVER_START_CMD="java -Xms512M -Xmx1024M -jar './${MAIN_EXECUTABLE}' nogui"
[[ -n "${SERVER_START_SUCCESS}" ]] && declare -r SERVER_START_SUCCESS=${SERVER_START_SUCCESS} || SERVER_START_SUCCESS="done"

# System parameters for the control script
[[ -n "${IDLE_SERVER}" ]]       && tmp_IDLE_SERVER=${IDLE_SERVER}   || IDLE_SERVER="false"
[[ -n "${IDLE_SESSION_NAME}" ]] && declare -r IDLE_SESSION_NAME=${IDLE_SESSION_NAME} || IDLE_SESSION_NAME="idle_server_${SESSION_NAME}"
[[ -n "${GAME_PORT}" ]]         && declare -r GAME_PORT=${GAME_PORT}       || GAME_PORT="25565"
[[ -n "${CHECK_PLAYER_TIME}" ]] && declare -r CHECK_PLAYER_TIME=${CHECK_PLAYER_TIME} || CHECK_PLAYER_TIME="30"
[[ -n "${IDLE_IF_TIME}" ]]      && declare -r IDLE_IF_TIME=${IDLE_IF_TIME} || IDLE_IF_TIME="1200"

# Additional configuration options which only few may need to alter
[[ -n "${GAME_COMMAND_DUMP}" ]] && declare -r GAME_COMMAND_DUMP=${GAME_COMMAND_DUMP} || GAME_COMMAND_DUMP="/tmp/${myname}_${SESSION_NAME}_command_dump.txt"

# Variables passed over the command line will always override the one from a config file
source /etc/conf.d/"${game}" 2>/dev/null || >&2 echo "Could not source /etc/conf.d/${game}"

# Preserve the content of IDLE_SERVER without making it readonly
[[ -n ${tmp_IDLE_SERVER} ]] && IDLE_SERVER=${tmp_IDLE_SERVER}


# Strictly disallow uninitialized Variables
set -u
# Exit if a single command breaks and its failure is not handled accordingly
set -e

MAX_SERVER_START_TIME=150

# Check whether sudo is needed at all
if [[ "$(whoami)" == "${GAME_USER}" ]]; then
	SUDO_CMD=""
else
	SUDO_CMD="sudo -u ${GAME_USER}"
fi

# Choose which flavor of netcat is to be used
if command -v netcat &> /dev/null; then
	NETCAT_CMD="netcat"
elif command -v ncat &> /dev/null; then
	NETCAT_CMD="ncat"
else
	NETCAT_CMD=""
fi

# Check for sudo rigths
if [[ "$(${SUDO_CMD} whoami)" != "${GAME_USER}" ]]; then
	>&2 echo -e "You have \e[39;1mno permission\e[0m to run commands as $GAME_USER user."
	exit 21
fi

# Pipe any given argument to the game server console,
# sleep for $sleep_time and return its output if $return_stdout is set
game_command() {
	${SUDO_CMD} tmux -L "${SESSION_NAME}" wait-for -L "command_lock"
	if [[ -z "${return_stdout:-}" ]]; then
		${SUDO_CMD} tmux -L "${SESSION_NAME}" send-keys -t "${SESSION_NAME}":0.0 "$*" Enter
	else
		${SUDO_CMD} tmux -L "${SESSION_NAME}" pipe-pane -t "${SESSION_NAME}":0.0 "cat > ${GAME_COMMAND_DUMP}"
		${SUDO_CMD} tmux -L "${SESSION_NAME}" send-keys -t "${SESSION_NAME}":0.0 "$*" Enter
		sleep "${sleep_time:-0.3}"
		${SUDO_CMD} tmux -L "${SESSION_NAME}" pipe-pane -t "${SESSION_NAME}":0.0
		${SUDO_CMD} cat "${GAME_COMMAND_DUMP}"
	fi
	${SUDO_CMD} tmux -L "${SESSION_NAME}" wait-for -U "command_lock"
}

# Check whether there are player on the server through list
is_player_online() {
	response="$(sleep_time=0.6 return_stdout=true game_command list)"
	# Delete leading line and fancy characters from free response string
	response="$(echo "${response}" | sed -r -e 's/\x1B\[([0-9]{1,2}(;[0-9]{1,2})*)?[JKmsuG]//g')"
	# The list command prints a line containing the usernames after the last occurrence of ": "
	# and since playernames may not contain this string the clean player-list can easily be retrieved.
	# Otherwise check the first digit after the last occurrence of "There are". If it is 0 then there
	# are no players on the server. Should this test fail as well. Assume that a player is online.
	if [[ $(echo "${response}" | grep ":" | sed -e 's/.*\: //' | tr -d '\n' | wc -c) -le 1 ]]; then
		# No player is online
		return 0
	elif [[ "x$(echo "${response}" | grep "There are" | sed -r -e 's/.*\: //' -e 's/^([^.]+).*$/\1/; s/^[^0-9]*([0-9]+).*$/\1/' | tr -d '\n')" == "x0" ]]; then
		# No player is online
		return 0
	else
		# A player is online (or it could not be determined)
		return 1
	fi
}

# Check whether the server is visited by a player otherwise shut it down
idle_server_daemon() {
	# This function is run within a tmux session of the GAME_USER therefore SUDO_CMD can be omitted
	if [[ "$(whoami)" != "${GAME_USER}" ]]; then
		>&2 echo "Somehow this hidden function was not executed by the ${GAME_USER} user."
		>&2 echo "This should not have happend. Are you messing around with this script? :P"
		exit 22
	fi

	# Time in seconds for which no player was on the server
	no_player=0

	while true; do
		printf "no_player: %10ss  check_player_time: %10ss  idle_if_time: %10ss\n" "${no_player}" "${CHECK_PLAYER_TIME}" "${IDLE_IF_TIME}"
		# Retry in ${CHECK_PLAYER_TIME} seconds
		sleep ${CHECK_PLAYER_TIME}

		if socket_has_session "${SESSION_NAME}"; then
			# Game server is up and running
			# Check for active player
			if [[ -n "$(tmux -L "${SESSION_NAME}" list-clients -t "${SESSION_NAME}":0.0 2> /dev/null)" ]]; then
				# An administrator is connected to the console, pause player checking
				echo "An admin is connected to the console. Pause player checking."
			elif SUDO_CMD="" is_player_online; then
				# No player was seen on the server through list
				no_player=$(( no_player + CHECK_PLAYER_TIME ))
				# Stop the game server if no player was active for at least ${IDLE_IF_TIME}
				if [[ "${no_player}" -ge "${IDLE_IF_TIME}" ]]; then
					IDLE_SERVER="false" ${myname} stop
					# Wait for game server to go down
					for i in {1..100}; do
						socket_has_session "${SESSION_NAME}" || break
						[[ $i -eq 100 ]] && echo -e "An \e[39;1merror\e[0m occurred while trying to reset the idle_server!"
						sleep 0.1
					done
					# Reset timer and give the player 300 seconds to connect after pinging
					no_player=$(( IDLE_IF_TIME - 300 ))
					# Game server is down, listen on port ${GAME_PORT} for incoming connections
					echo -n "Netcat: "
					${NETCAT_CMD} -v -l -p ${GAME_PORT} 2>&1 | (grep -m1 -i "connect" && pkill -P $$ ${NETCAT_CMD}) || true
					echo "Netcat caught a connection. The server is coming up again..."
					IDLE_SERVER="false" ${myname} start
				fi
			else
				# Reset timer since there is an active player on the server
				no_player=0
			fi
		else
			# Reset timer and give the player 300 seconds to connect after pinging
			no_player=$(( IDLE_IF_TIME - 300 ))
			# Game server is down, listen on port ${GAME_PORT} for incoming connections
			echo -n "Netcat: "
			${NETCAT_CMD} -v -l -p ${GAME_PORT} 2>&1 | (grep -m1 -i "connect" && pkill -P $$ ${NETCAT_CMD}) || true
			echo "Netcat caught a connection. The server is coming up again..."
			IDLE_SERVER="false" ${myname} start
		fi
	done
}

# Start the server if it is not already running
server_start() {
	# Start the game server
	if socket_has_session "${SESSION_NAME}"; then
		echo "A tmux ${SESSION_NAME} session is already running. Please close it first."
	else
		echo -en "Starting server..."
		${SUDO_CMD} rm -f "${GAME_COMMAND_DUMP}"
		# Use a plain file as command buffers for the server startup and switch to a FIFO pipe later
		${SUDO_CMD} touch "${GAME_COMMAND_DUMP}"
		# Ensure pipe-pine is started before the server itself by splitting the session creation and server startup
		${SUDO_CMD} tmux -L "${SESSION_NAME}" new-session -s "${SESSION_NAME}" -c "${SERVER_ROOT}" -d /bin/bash
		${SUDO_CMD} tmux -L "${SESSION_NAME}" wait-for -L "command_lock"
		${SUDO_CMD} tmux -L "${SESSION_NAME}" pipe-pane -t "${SESSION_NAME}":0.0 "cat > ${GAME_COMMAND_DUMP}"
		${SUDO_CMD} tmux -L "${SESSION_NAME}" send-keys -t "${SESSION_NAME}":0.0 "exec ${SERVER_START_CMD}" Enter
		for ((i=1; i<=MAX_SERVER_START_TIME; i++)); do
			sleep "${sleep_time:-0.1}"
			if ! socket_session_is_alive "${SESSION_NAME}"; then
				echo -e "\e[39;1m failed\e[0m\n"
				>&2 ${SUDO_CMD} cat "${GAME_COMMAND_DUMP}"
				${SUDO_CMD} rm -f "${GAME_COMMAND_DUMP}"
				# Session is dead but remain-on-exit left it open; close it for sure
				${SUDO_CMD} tmux -L "${SESSION_NAME}" kill-session -t "${SESSION_NAME}"
				exit 1
			elif grep -q -i "${SERVER_START_SUCCESS}" "${GAME_COMMAND_DUMP}"; then
				echo -e "\e[39;1m done\e[0m"
				break
			elif [[ $i -eq ${MAX_SERVER_START_TIME} ]]; then
				echo -e "\e[39;1m skipping\e[0m"
				>&2 echo -e "Server startup has not finished yet; continuing anyways"
			fi
		done
		${SUDO_CMD} tmux -L "${SESSION_NAME}" pipe-pane -t "${SESSION_NAME}":0.0
		# Let the command buffer be a FIFO pipe
		${SUDO_CMD} rm -f "${GAME_COMMAND_DUMP}"
		${SUDO_CMD} mkfifo "${GAME_COMMAND_DUMP}"
		${SUDO_CMD} tmux -L "${SESSION_NAME}" wait-for -U "command_lock"

		# Mimic GNU screen and allow for both C-a and C-b as prefix
		${SUDO_CMD} tmux -L "${SESSION_NAME}" set -g prefix2 C-a
	fi

	if [[ "${IDLE_SERVER,,}" == "true" ]]; then
		# Check for the availability of the netcat (nc) binaries
		if [[ -z "${NETCAT_CMD}" ]]; then
			>&2 echo "The netcat binaries are needed for suspending an idle server."
			exit 12
		fi

		# Start the idle server daemon
		if socket_has_session "${IDLE_SESSION_NAME}"; then
			${SUDO_CMD} tmux -L "${SESSION_NAME}" kill-session -t "${IDLE_SESSION_NAME}"
			# Restart as soon as the idle_server_daemon has shut down completely
			for i in {1..100}; do
				sleep 0.1
				if ! socket_has_session "${IDLE_SESSION_NAME}"; then
					${SUDO_CMD} tmux -L "${SESSION_NAME}" new-session -s "${IDLE_SESSION_NAME}" -d "${myname} idle_server_daemon"
					break
				fi
				[[ $i -eq 100 ]] && echo -e "An \e[39;1merror\e[0m occurred while trying to reset the idle_server!"
			done
		else
			echo -en "Starting idle server daemon..."
			${SUDO_CMD} tmux -L "${SESSION_NAME}" new-session -s "${IDLE_SESSION_NAME}" -d "${myname} idle_server_daemon"
			echo -e "\e[39;1m done\e[0m"
		fi
	fi
}

# Stop the server gracefully by saving everything prior and warning the users
server_stop() {
	# Quit the idle daemon
	if [[ "${IDLE_SERVER,,}" == "true" ]]; then
		# Check for the availability of the netcat (nc) binaries
		if [[ -z "${NETCAT_CMD}" ]]; then
			>&2 echo "The netcat binaries are needed for suspending an idle server."
			exit 12
		fi

		if socket_has_session "${IDLE_SESSION_NAME}"; then
			echo -en "Stopping idle server daemon..."
			${SUDO_CMD} tmux -L "${SESSION_NAME}" kill-session -t "${IDLE_SESSION_NAME}"
			echo -e "\e[39;1m done\e[0m"
		else
			echo "The corresponding tmux session for ${IDLE_SESSION_NAME} was already dead."
		fi
	fi

	# Gracefully exit the game server
	if socket_has_session "${SESSION_NAME}"; then
		# Game server is up and running, gracefully stop the server when there are still active players

		# Check for active player
		if is_player_online; then
			# No player was seen on the server through list
			echo -en "Server is going down..."
			game_command stop
		else
			# Player(s) were seen on the server through list (or an error occurred)
			# Warning the users through the server console
			game_command say "Server is going down in 10 seconds! HURRY UP WITH WHATEVER YOU ARE DOING!"
			game_command save-all
			echo -en "Server is going down in..."
			for i in {1..10}; do
				game_command say "down in... $(( 10 - i ))"
				echo -n " $(( 10 - i ))"
				sleep 1
			done
			game_command stop
		fi

		# Finish as soon as the server has shut down completely
		for i in {1..100}; do
			if ! socket_has_session "${SESSION_NAME}"; then
				${SUDO_CMD} rm -f "${GAME_COMMAND_DUMP}"
				echo -e "\e[39;1m done\e[0m"
				break
			fi
			[[ $i -eq 100 ]] && echo -e "\e[39;1m timed out\e[0m"
			sleep 0.1
		done
	else
		echo "The corresponding tmux session for ${SESSION_NAME} was already dead."
	fi
}

# Print whether the server is running and if so give some information about memory usage and threads
server_status() {
	# Print status information about the idle daemon
	if [[ "${IDLE_SERVER,,}" == "true" ]]; then
		# Check for the availability of the netcat (nc) binaries
		if [[ -z "${NETCAT_CMD}" ]]; then
			>&2 echo "The netcat binaries are needed for suspending an idle server."
			exit 12
		fi

		if socket_has_session "${IDLE_SESSION_NAME}"; then
			echo -e "Idle server daemon status:\e[39;1m running\e[0m"
		else
			echo -e "Idle server daemon status:\e[39;1m stopped\e[0m"
		fi
	fi

	# Print status information for the game server
	if socket_has_session "${SESSION_NAME}"; then
		echo -e "Status:\e[39;1m running\e[0m"

		# Calculating memory usage
		for p in $(${SUDO_CMD} pgrep -f "${MAIN_EXECUTABLE}"); do
			ps -p"${p}" -O rss | tail -n 1;
		done | gawk '{ count ++; sum += $2 }; END {count --; print "Number of processes =", count, "(tmux +", count, "x server)"; print "Total memory usage =", sum/1024, "MB" ;};'
	else
		echo -e "Status:\e[39;1m stopped\e[0m"
	fi
}

# Restart the complete server by shutting it down and starting it again
server_restart() {
	if socket_has_session "${SESSION_NAME}"; then
		server_stop
		server_start
	else
		server_start
	fi
}

# Backup the directories specified in BACKUP_PATHS
backup_files() {
	# Check for the availability of the tar binaries
	if ! command -v tar &> /dev/null; then
		>&2 echo "The tar binaries are needed for a backup."
		exit 11
	fi

	echo "Starting backup..."
	fname="$(date +%Y_%m_%d_%H.%M.%S).tar.gz"
	${SUDO_CMD} mkdir -p "${BACKUP_DEST}"
	if socket_has_session "${SESSION_NAME}"; then
		game_command save-off
		game_command save-all
		sync && wait
		${SUDO_CMD} tar -C "${SERVER_ROOT}" -cf "${BACKUP_DEST}/${fname}" ${BACKUP_PATHS} --totals ${BACKUP_FLAGS} 2>&1 | grep -v "tar: Removing leading "
		game_command save-on
	else
		${SUDO_CMD} tar -C "${SERVER_ROOT}" -cf "${BACKUP_DEST}/${fname}" ${BACKUP_PATHS} --totals ${BACKUP_FLAGS} 2>&1 | grep -v "tar: Removing leading "
	fi
	echo -e "\e[39;1mbackup completed\e[0m\n"

	echo -n "Only keeping the last ${KEEP_BACKUPS} backups and removing the other ones..."
	backup_count=$(for f in "${BACKUP_DEST}"/[0-9_.]*; do echo "${f}"; done | wc -l)
	if [[ $(( backup_count - KEEP_BACKUPS )) -gt 0 ]]; then
		for old_backup in $(for f in "${BACKUP_DEST}"/[0-9_.]*; do echo "${f}"; done | head -n"$(( backup_count - KEEP_BACKUPS ))"); do
			${SUDO_CMD} rm "${old_backup}";
		done
		echo -e "\e[39;1m done\e[0m ($(( backup_count - KEEP_BACKUPS)) backup(s) pruned)"
	else
		echo -e "\e[39;1m done\e[0m (no backups pruned)"
	fi
}

# Restore backup
backup_restore() {
	# Check for the availability of the tar binaries
	if ! command -v tar &> /dev/null; then
		>&2 echo "The tar binaries are needed for a backup."
		exit 11
	fi

	# Only allow the user to restore a backup if the server is down
	if socket_has_session "${SESSION_NAME}"; then
		>&2 echo -e "The \e[39;1mserver should be down\e[0m in order to restore the world data."
		exit 3
	fi

	# Either let the user choose a backup or expect one as an argument
	if [[ $# -lt 1 ]]; then
		echo "Please enter the corresponding number for the backup to be restored: "
		i=1
		for f in "${BACKUP_DEST}"/[0-9_.]*; do
			echo -e "    \e[39;1m$i)\e[0m\t$f"
			i=$(( i + 1 ))
		done
		echo -en "Restore backup number: "

		# Read in user input
		read -r user_choice

		# Interpeting the input
		if [[ $user_choice =~ ^-?[0-9]+$ ]]; then
			n=1
			for f in "${BACKUP_DEST}"/[0-9_.]*; do
				[[ ${n} -eq $user_choice ]] && fname="$f"
				n=$(( n + 1 ))
			done
			if [[ -z $fname ]]; then
				>&2 echo -e "\e[39;1mFailed\e[0m to interpret your input. Please enter the digit of the presented options."
				exit 5
			fi
		else
			>&2 echo -e "\e[39;1mFailed\e[0m to interpret your input. Please enter a valid digit for one of the presented options."
			exit 6
		fi
	elif [[ $# -eq 1 ]]; then
		# Check for the existance of the specified file
		if [[ -f "$1" ]]; then
			fname="$1"
		else
			if [[ -f "${BACKUP_DEST}"/"$1" ]]; then
				fname="${BACKUP_DEST}"/"$1"
			else
				>&2 echo -e "Sorry, but '$1', is \e[39;1mnot a valid file\e[0m, neither in your current directory nor in the backup folder."
				exit 4
			fi
		fi
	elif [[ $# -gt 1 ]]; then
		>&2 echo -e "\e[39;1mToo many arguments.\e[0m Please pass only the filename for the world data as an argument."
		>&2 echo "Or alternatively, no arguments at all to choose from a list of available backups."
		exit 7
	fi

	echo "Restoring backup..."
	if ${SUDO_CMD} tar -xf "${fname}" -C "${SERVER_ROOT}" 2>&1; then
		echo -e "\e[39;1mRestoration completed\e[0m"
	else
		echo -e "\e[39;1mFailed to restore backup.\e[0m"
	fi
}

# Run the given command at the game server console
server_command() {
	if [[ $# -lt 1 ]]; then
		>&2 echo "No server command specified. Try 'help' for a list of commands."
		exit 1
	fi

	if socket_has_session "${SESSION_NAME}"; then
		return_stdout=true game_command "$@"
	else
		echo "There is no ${SESSION_NAME} session to connect to."
	fi
}

# Enter the tmux game session
server_console() {
	if socket_has_session "${SESSION_NAME}"; then
		${SUDO_CMD} tmux -L "${SESSION_NAME}" attach -t "${SESSION_NAME}":0.0
	else
		echo "There is no ${SESSION_NAME} session to connect to."
	fi
}

# Check if there is a session available
socket_has_session() {
	if [[ "$(whoami)" != "${GAME_USER}" ]]; then
		${SUDO_CMD} tmux -L "${SESSION_NAME}" has-session -t "${1}":0.0 2> /dev/null
		return $?
	fi
	tmux -L "${SESSION_NAME}" has-session -t "${1}":0.0 2> /dev/null
	return $?
}

socket_session_is_alive() {
	if socket_has_session "${1}"; then
		if [[ "$(whoami)" != "${GAME_USER}" ]]; then
			return $(${SUDO_CMD} tmux -L "${SESSION_NAME}" list-panes -t "${1}":0.0 -F '#{pane_dead}' 2> /dev/null)
		fi
		return $(tmux -L "${SESSION_NAME}" list-panes -t "${1}":0.0 -F '#{pane_dead}' 2> /dev/null)
	else
		return 1
	fi
}

# Help function, no arguments required
help() {
	cat <<-EOF
	This script was designed to easily control any ${game} server. Almost any parameter for a given
	${game} server derivative can be changed by editing the variables in the configuration file.

	Usage: ${myname} {start|stop|restart|status|backup|restore|command <command>|console}
	    start                Start the ${game} server
	    stop                 Stop the ${game} server
	    restart              Restart the ${game} server
	    status               Print some status information
	    backup               Backup the world data
	    restore [filename]   Restore the world data from a backup
	    command <command>    Run the given command at the ${game} server console
	    console              Enter the server console through a tmux session

	Copyright (c) Gordian Edenhofer <gordian.edenhofer@gmail.com>
	EOF
}

case "${1:-}" in
	start)
	server_start
	;;

	stop)
	server_stop
	;;

	status)
	server_status
	;;

	restart)
	server_restart
	;;

	console)
	server_console
	;;

	command)
	server_command "${@:2}"
	;;

	backup)
	backup_files
	;;

	restore)
	backup_restore "${@:2}"
	;;

	idle_server_daemon)
	# This shall be a hidden function which should only be invoked internally
	idle_server_daemon
	;;

	-h|--help)
	help
	exit 0
	;;

	*)
	help
	exit 1
	;;
esac

exit 0
