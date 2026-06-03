import Foundation

struct EmojiCategory {
    let name: String
    let icon: String
    let emojis: [String]
}

/// Static catalog of unicode emojis for the reaction picker / library.
/// Direct port of the Android client's `EmojiData.kt`.
enum EmojiData {
    static let defaultQuickReactions: [String] = [
        "🧡", "👍", "👎", "🤙", "🚀", "🤗", "😂", "😢", "👨‍💻", "👀", "✅", "🤡", "🐸", "💀", "⚡", "🙏", "🍆"
    ]

    static let categories: [EmojiCategory] = [
        EmojiCategory(
            name: "Smileys",
            icon: "😀",
            emojis: [
                "😀", "😃", "😄", "😁", "😆",
                "😅", "😂", "🤣", "🥲", "🥹",
                "😊", "😇", "🙂", "🙃", "🫠",
                "😉", "😌", "😍", "🥰", "😘",
                "😗", "😙", "😚", "😋", "😛",
                "😜", "🤪", "😝", "🤑", "🤗",
                "🫡", "🤭", "🫢", "🫣", "🤫",
                "🤔", "🫤", "🤐", "🤨", "😐",
                "😑", "😶", "😶‍🌫️", "🫥", "😏",
                "😒", "🙄", "😬", "🤥", "😮‍💨",
                "🫨", "🙂‍↔️", "🙂‍↕️",
                "😔", "😪", "🤤", "😴",
                "😷", "🤒", "🤕", "🤢", "🤮",
                "🤧", "🥵", "🥶", "🥴", "😵",
                "😵‍💫", "🤯", "🤠", "🥳", "🥸",
                "😎", "🤓", "🧐", "😕", "😟",
                "🙁", "☹️", "😮", "😯", "😲",
                "😳", "🥺", "😦", "😧", "😨",
                "😰", "😥", "😢", "😭", "😱",
                "😖", "😣", "😞", "😓", "😩",
                "😤", "😠", "😡", "🤬", "😈",
                "👿", "💀", "☠️", "💩", "🤡",
                "👹", "👺", "👻", "👽", "👾",
                "🤖", "😺", "😸", "😹", "😻",
                "😼", "😽", "🙀", "😿", "😾",
                "🙈", "🙉", "🙊"
            ]
        ),
        EmojiCategory(
            name: "People",
            icon: "👋",
            emojis: [
                "👋", "🤚", "🖐️", "✋", "🖖",
                "🫱", "🫲", "🫳", "🫴", "🫵",
                "🫷", "🫸",
                "👌", "🤌", "🤏", "✌️", "🤞",
                "🫰", "🤟", "🤘", "🤙", "👈",
                "👉", "👆", "🖕", "👇", "☝️",
                "👍", "👎", "✊", "👊", "🤛",
                "🤜", "👏", "🙌", "🫶", "👐",
                "🤲", "🤝", "🙏", "✍️", "💅",
                "🤳",
                "💪", "🦾", "🦿", "🦵", "🦶",
                "👂", "🦻", "👃", "🧠", "🫀",
                "🫁", "🦷", "🦴", "👀", "👁️",
                "👅", "👄", "🫦", "👶", "🧒",
                "👦", "👧", "🧑", "👱", "👨",
                "🧔", "👩", "🧓", "👴", "👵",
                "🙍", "🙎", "🙅", "🙆", "💁",
                "🙋", "🧏", "🙇", "🤦", "🤷",
                "🫂", "👫", "👬", "👭",
                "👮", "🕵️", "💂", "🥷", "👷",
                "🫅", "🤴", "👸", "👳", "👲",
                "🧕", "🤵", "👰", "🤰", "🫃",
                "🫄", "🤱", "🧑‍🍼", "👼", "🎅",
                "🤶", "🦸", "🦹", "🧚", "🧛",
                "🧜", "🧝", "🧞", "🧟", "🧌",
                "👨‍💻", "👩‍💻", "👨‍🚀", "👩‍🚀",
                "👨‍🎤", "👩‍🎤", "👨‍🎨", "👩‍🎨",
                "👨‍🍳", "👩‍🍳", "🧑‍⚕️", "🧑‍🏫",
                "🧑‍🌾", "🧑‍🔬", "🧑‍🔧", "🧑‍💼",
                "🧑‍🏭", "🧑‍🎓", "🧑‍✈️", "🧑‍🚒",
                "🧑‍🦯", "🧑‍🦼", "🧑‍🦽",
                "👨‍👩‍👦", "👨‍👩‍👧"
            ]
        ),
        EmojiCategory(
            name: "Animals",
            icon: "🐶",
            emojis: [
                "🐶", "🐱", "🐭", "🐹", "🐰",
                "🦊", "🐻", "🐼", "🐨", "🐯",
                "🦁", "🐮", "🐷", "🐸", "🐵",
                "🙈", "🙉", "🙊", "🐒", "🐔",
                "🐧", "🐦", "🐤", "🐣", "🐥",
                "🦆", "🦅", "🦉", "🦤", "🦩",
                "🦚", "🦜", "🪽", "🐦‍🔥", "🪶",
                "🐊", "🐢", "🦎", "🐍", "🐲",
                "🐉", "🦕", "🦖", "🐳", "🐋",
                "🐬", "🦭", "🐟", "🐠", "🐡",
                "🦈", "🐙", "🦑", "🦐", "🪸",
                "🦞", "🦀", "🐚", "🪼", "🐌",
                "🦋", "🐛", "🐜", "🐝", "🪲",
                "🐞", "🦗", "🪳", "🪰", "🦟",
                "🦂", "🕷️", "🕸️", "🪱", "🦠",
                "🐺", "🐗", "🦌", "🫎", "🫏",
                "🐪", "🐫", "🦙", "🦒", "🐘",
                "🦣", "🦏", "🦛", "🐃", "🐂",
                "🐄", "🐎", "🐖", "🐏", "🐑",
                "🦬", "🦃", "🐓", "🐐", "🦘",
                "🦡", "🦫", "🦥", "🦦", "🦨",
                "🦔", "🐕", "🦮", "🐕‍🦺", "🐈",
                "🐈‍⬛", "🐁", "🐀", "🐿️",
                "🐇", "🐻‍❄️", "🦧", "🐾",
                "🪹", "🪺", "🪿", "🐦‍⬛",
                "🌷", "🌹", "🥀", "🪷", "🪻",
                "🌺", "🌸", "🌼", "🌻", "💐",
                "🍀", "🍁", "🍂", "🍃", "🪴",
                "🌵", "🎋", "🎍", "🪨", "🪵"
            ]
        ),
        EmojiCategory(
            name: "Food",
            icon: "🍔",
            emojis: [
                "🍎", "🍏", "🍊", "🍋", "🍋‍🟩", "🍌",
                "🍉", "🍇", "🍓", "🫐", "🍈",
                "🍒", "🍑", "🥭", "🍍", "🥥",
                "🥝", "🍅", "🍆", "🥑", "🥦",
                "🥬", "🥒", "🌶️", "🫑", "🌽",
                "🥕", "🧄", "🧅", "🥔", "🍠",
                "🫘", "🥜", "🌰", "🍄", "🫒",
                "🥐", "🍞", "🥖", "🫓", "🥨",
                "🥯", "🧀", "🥞", "🧇",
                "🍖", "🍗", "🥩", "🥓",
                "🍔", "🍟", "🍕", "🌭", "🥪",
                "🌮", "🌯", "🫔", "🥙", "🧆",
                "🥚", "🍳", "🥘", "🍲", "🫕",
                "🥣", "🥗", "🍿", "🧈", "🧂",
                "🥫", "🍱", "🍘", "🍙", "🍚",
                "🍛", "🍜", "🍝", "🍣", "🍤",
                "🍥", "🥟", "🥠", "🥡", "🥢",
                "🍡", "🥮",
                "🍦", "🍧", "🍨", "🍩", "🍪",
                "🎂", "🍰", "🧁", "🥧", "🍫",
                "🍬", "🍭", "🍮", "🍯",
                "🍼", "🥛", "☕", "🫖", "🍵",
                "🍶", "🍺", "🍻", "🥂", "🍷",
                "🥃", "🍸", "🍹", "🍾", "🧃",
                "🧉", "🧋", "🧊", "🥤", "🫗",
                "🫙", "🫚", "🫛"
            ]
        ),
        EmojiCategory(
            name: "Activities",
            icon: "⚽",
            emojis: [
                "⚽", "🏀", "🏈", "⚾", "🥎",
                "🎾", "🏐", "🏉", "🥏", "🎱",
                "🏓", "🏸", "🏒", "🥍", "🏑",
                "🥅", "⛳", "🏹", "🎣", "🤿",
                "🥊", "🥋", "🥌", "🛹", "🛼",
                "🛷", "⛸️", "🎿",
                "🤼", "🤸", "🏄", "🚴", "🧗",
                "🤺", "🏇", "🏊", "🤽", "🤾",
                "⛷️", "🏂", "🏋️", "🏌️", "🤹",
                "🎪", "🎭", "🎨",
                "🎤", "🎧", "🎼", "🎵", "🎶",
                "🎙️", "🎚️", "🎛️",
                "🎹", "🥁", "🪘", "🎷", "🎺",
                "🎸", "🪕", "🎻", "🪗", "🪈",
                "🎬", "🎮", "🕹️", "🎰", "🎲",
                "🧩", "🪀", "🪁", "🎯", "🎳",
                "🪅", "🪆",
                "🏆", "🏅", "🥇", "🥈", "🥉",
                "🏵️", "🎖️", "🎗️",
                "🎠", "🎡", "🎢", "🎫", "🎟️"
            ]
        ),
        EmojiCategory(
            name: "Travel",
            icon: "✈️",
            emojis: [
                "🚗", "🚕", "🚙", "🛻", "🚌",
                "🚎", "🏎️", "🚓", "🚑", "🚒",
                "🚐", "🛺", "🚚", "🚛", "🚜",
                "🛵", "🏍️", "🚲", "🛴",
                "🚨", "🚔", "🚍", "🚘", "🚖",
                "🚡", "🚠", "🚟", "🚂", "🚃",
                "🚄", "🚅", "🚆", "🚇", "🚈",
                "🚉", "🚊", "🛞",
                "🚢", "⛵", "🛶", "🚤", "🛥️",
                "🛳️", "✈️", "🛫", "🛬", "🪂",
                "💺", "🚁", "🛸", "🚀",
                "⛽", "🚏", "🛣️", "🛤️",
                "🏠", "🏡", "🏢", "🏣", "🏤",
                "🏥", "🏦", "🏨", "🏪", "🏫",
                "🏬", "🏭", "🏯", "🏰", "🗼",
                "🗽", "⛪", "🕌", "🛕", "🕍",
                "⛩️", "🕋", "⛲", "⛺", "🏕️",
                "🌁", "🌃", "🏙️", "🌅", "🌄",
                "🌆", "🌇", "🌉", "🌌", "🌠",
                "🎇", "🎆", "🌈",
                "🌍", "🌎", "🌏", "🌋", "⛰️",
                "🏔️", "🏖️", "🏜️", "🏝️", "🏞️",
                "🏟️", "🪐",
                "☀️", "🌤️", "⛅", "🌥️", "🌦️",
                "🌧️", "⛈️", "🌩️", "🌨️", "❄️",
                "☃️", "⛄", "🌪️", "🌫️", "🌬️",
                "🌀", "🌊", "💧", "💦", "☔",
                "⛱️", "🌙", "🌛", "🌜", "🌝",
                "🌞", "🌑", "🌒", "🌓", "🌔",
                "🌕", "🌖", "🌗", "🌘", "⭐",
                "☄️",
                "🌺", "🌸", "🌼", "🌻", "🌹",
                "🌷", "💐", "🍁", "🍂", "🍃",
                "🌿", "🍀", "🌾", "🌱", "🌲",
                "🌳", "🌴", "🌵", "🎋", "🎍",
                "🪨", "🪵"
            ]
        ),
        EmojiCategory(
            name: "Objects",
            icon: "💡",
            emojis: [
                "⌚", "📱", "📲", "💻", "⌨️",
                "🖥️", "🖨️", "🖱️", "🖲️", "🕹️",
                "💽", "💾", "💿", "📀", "📷",
                "📸", "📹", "🎥", "📽️", "📺",
                "📻", "📟", "📠", "📡", "🔋",
                "🪫", "🔌", "💡", "🔦", "🕯️",
                "🪔", "🧯", "🛒", "📦",
                "📫", "📪", "📬", "📭", "📮",
                "📧", "📨", "📩", "📜", "📃",
                "📄", "📁", "📂", "📅", "📆",
                "🗓️", "📇", "📈", "📉", "📊",
                "📋", "📌", "📍", "📎", "🖇️",
                "📏", "📐", "✂️", "📝", "✏️",
                "🖊️", "🖋️", "🖌️", "🖍️", "📚",
                "📖", "📓", "📔", "📕", "📗",
                "📘", "📙", "📰", "🗞️", "🔍",
                "🔎", "🔏", "🔐", "🔑", "🗝️",
                "🔨", "🪓", "⛏️", "⚒️", "🪚",
                "🔧", "🪛", "🔩", "⚙️", "🗜️",
                "⚖️", "🔗", "⛓️", "🪝", "🧲",
                "🔫", "💣", "🧨", "🛡️",
                "🧰", "🧪", "🧫", "🧬", "🔬",
                "🔭", "🩺", "🩻", "💊", "💉",
                "🩸", "🩹", "🩼",
                "🧴", "🧷", "🪡", "🧵", "🧶",
                "🪢", "🪣", "🧹", "🧺", "🧻",
                "🪠", "🚽", "🚰", "🚿", "🛁",
                "🪥", "🧼", "🫧", "🪒", "🧽",
                "🪞", "🪟", "🛋️", "🪑", "🚪",
                "🛏️", "🧸",
                "🔮", "🪄", "🧿", "🪬", "🪯",
                "🛜", "🪭", "🪮", "🪇",
                "🎁", "🎈", "🎉", "🎊", "🎀",
                "🧧", "🏮", "💈", "🪩",
                "🎎", "🎏", "🎐", "🎑",
                "🧳", "👜", "👝", "🎒", "🧢",
                "👒", "🎩", "🎓", "⛑️", "💼",
                "👑", "💍", "💎", "📿",
                "👗", "👘", "🥻", "👙", "🩱",
                "👚", "👔", "👕", "🩲", "🩳",
                "👖", "🧣", "🧤", "🧥", "🧦",
                "👟", "👞", "🥾", "🥿", "👠",
                "👡", "👢", "🩴", "🪖", "👛",
                "🖼️"
            ]
        ),
        EmojiCategory(
            name: "Symbols",
            icon: "❤️",
            emojis: [
                "❤️", "🧡", "💛", "💚", "💙",
                "💜", "🖤", "🤍", "🤎", "🩷",
                "🩵", "🩶", "❤️‍🔥", "❤️‍🩹", "💔",
                "❣️", "💕", "💞", "💓", "💗",
                "💖", "💘", "💝", "💟", "♾️",
                "☮️", "✝️", "☪️", "🕉️", "☸️",
                "✡️", "🔯", "🕎", "☯️", "☦️",
                "🛐", "⛎", "♈", "♉", "♊",
                "♋", "♌", "♍", "♎", "♏",
                "♐", "♑", "♒", "♓", "🆔",
                "⚛️", "♀️", "♂️", "⚧️",
                "♻️", "🔚", "🔛", "🔜", "🔝",
                "🔙", "⚡", "🔥", "💥", "✨",
                "🌟", "💫", "💢", "💬", "💭",
                "🗯️", "👁️‍🗨️", "💯", "❗", "❓",
                "❕", "❔", "‼️", "⁉️", "✅",
                "☑️", "✔️", "❌", "❎", "➕",
                "➖", "➗", "✖️", "➰", "➿",
                "✳️", "✴️", "〰️", "©️", "®️", "™️",
                "🔶", "🔷", "🔸", "🔹", "🔺",
                "🔻", "💠", "🔘", "🔲", "🔳",
                "⬛", "⬜", "◼️", "◻️", "◾", "◽",
                "▪️", "▫️",
                "🟥", "🟧", "🟨", "🟩", "🟦",
                "🟪", "🟫",
                "🔴", "🟠", "🟡", "🟢", "🔵",
                "🟣", "🟤", "⚫", "⚪",
                "🔔", "🔕", "📣", "📢", "🔇",
                "🔈", "🔉", "🔊",
                "▶️", "⏸️", "⏹️", "⏺️", "⏭️",
                "⏮️", "⏩", "⏪", "⏫", "⏬",
                "🔀", "🔁", "🔂",
                "🆕", "🆓", "🆙", "🆒", "🆗",
                "🆖", "🅰️", "🅱️", "🆎", "🅾️"
            ]
        ),
        EmojiCategory(
            name: "Flags",
            icon: "🏴‍☠️",
            emojis: [
                // Generic + identity flags
                "🏳️", "🏴", "🏁", "🚩", "🎌",
                "🏳️‍🌈", "🏳️‍⚧️", "🏴‍☠️",
                // Americas
                "🇦🇷", "🇧🇴", "🇧🇷", "🇨🇦", "🇨🇱",
                "🇨🇴", "🇨🇷", "🇨🇺", "🇩🇴", "🇪🇨",
                "🇬🇹", "🇭🇳", "🇭🇹", "🇯🇲", "🇲🇽",
                "🇳🇮", "🇵🇦", "🇵🇪", "🇵🇷", "🇵🇾",
                "🇸🇻", "🇹🇹", "🇺🇸", "🇺🇾", "🇻🇪",
                // Europe
                "🇦🇱", "🇦🇹", "🇧🇦", "🇧🇪", "🇧🇬",
                "🇧🇾", "🇨🇭", "🇨🇾", "🇨🇿", "🇩🇪",
                "🇩🇰", "🇪🇪", "🇪🇸", "🇪🇺", "🇫🇮",
                "🇫🇷", "🇬🇧", "🇬🇪", "🇬🇷", "🇭🇷",
                "🇭🇺", "🇮🇪", "🇮🇸", "🇮🇹", "🇱🇹",
                "🇱🇺", "🇱🇻", "🇲🇩", "🇲🇪", "🇲🇰",
                "🇲🇹", "🇳🇱", "🇳🇴", "🇵🇱", "🇵🇹",
                "🇷🇴", "🇷🇸", "🇷🇺", "🇸🇪", "🇸🇮",
                "🇸🇰", "🇹🇷", "🇺🇦", "🇻🇦",
                // Middle East
                "🇦🇪", "🇦🇲", "🇦🇿", "🇧🇭", "🇮🇱",
                "🇮🇶", "🇮🇷", "🇯🇴", "🇰🇼", "🇱🇧",
                "🇴🇲", "🇵🇸", "🇶🇦", "🇸🇦", "🇸🇾",
                "🇾🇪",
                // Africa
                "🇩🇿", "🇦🇴", "🇧🇼", "🇨🇩", "🇨🇲",
                "🇨🇮", "🇪🇬", "🇪🇹", "🇬🇭", "🇰🇪",
                "🇱🇾", "🇲🇦", "🇲🇿", "🇳🇦", "🇳🇬",
                "🇷🇼", "🇸🇩", "🇸🇳", "🇸🇴", "🇸🇸",
                "🇹🇳", "🇹🇿", "🇺🇬", "🇿🇦", "🇿🇲",
                "🇿🇼",
                // Asia
                "🇦🇫", "🇧🇩", "🇧🇳", "🇧🇹", "🇨🇳",
                "🇭🇰", "🇮🇩", "🇮🇳", "🇯🇵", "🇰🇭",
                "🇰🇿", "🇰🇬", "🇰🇵", "🇰🇷", "🇱🇦",
                "🇱🇰", "🇲🇲", "🇲🇳", "🇲🇴", "🇲🇻",
                "🇲🇾", "🇳🇵", "🇵🇰", "🇵🇭", "🇸🇬",
                "🇹🇭", "🇹🇯", "🇹🇲", "🇹🇼", "🇺🇿",
                "🇻🇳",
                // Oceania
                "🇦🇺", "🇫🇯", "🇳🇿", "🇵🇬", "🇸🇧",
                "🇼🇸"
            ]
        )
    ]

    /// Flat list of every unicode emoji across categories, in display order.
    static let allEmojis: [String] = categories.flatMap { $0.emojis }

    /// Lazy lowercased Unicode-name lookup keyed by emoji character. Built on
    /// first access using `String.applyingTransform(.toUnicodeName, ...)` so we
    /// don't ship a hardcoded keyword table — the OS already has the data.
    /// Used by `searchEmojis(_:)` for the library's search field.
    static let nameByEmoji: [String: String] = {
        var map: [String: String] = [:]
        for emoji in allEmojis {
            // `applyingTransform(.toUnicodeName)` returns sequences like
            // `\N{FACE WITH TEARS OF JOY}` — keep the words, drop the wrapper.
            guard let raw = emoji.applyingTransform(.toUnicodeName, reverse: false) else { continue }
            let cleaned = raw
                .replacingOccurrences(of: "\\N{", with: "")
                .replacingOccurrences(of: "}", with: " ")
                .lowercased()
            map[emoji] = cleaned
        }
        return map
    }()

    /// Supplemental keyword aliases for emoji whose Unicode name doesn't
    /// match common search terms. The Unicode name path catches the formal
    /// description (😂 → "face with tears of joy"), but users type colloquial
    /// terms like "lol", "cry", "fire". Each alias becomes a hit for the
    /// emoji it maps to in `searchEmojis(_:)`.
    static let keywordAliases: [String: [String]] = [
        "😂": ["lol", "lmao", "laugh", "laughing", "joy", "crying"],
        "🤣": ["rofl", "lmao", "laugh", "laughing"],
        "😭": ["cry", "crying", "sad", "sob", "tears"],
        "😢": ["cry", "crying", "sad", "tear"],
        "😍": ["love", "heart", "eyes"],
        "🥰": ["love", "loved", "hearts", "affection"],
        "❤️": ["love", "heart", "red"],
        "🧡": ["love", "heart", "orange"],
        "💛": ["love", "heart", "yellow"],
        "💚": ["love", "heart", "green"],
        "💙": ["love", "heart", "blue"],
        "💜": ["love", "heart", "purple"],
        "🖤": ["love", "heart", "black"],
        "🤍": ["love", "heart", "white"],
        "🤎": ["love", "heart", "brown"],
        "💔": ["heart", "break", "broken", "sad"],
        "💕": ["love", "heart", "hearts"],
        "💖": ["love", "heart", "sparkle"],
        "🔥": ["fire", "lit", "hot", "flame"],
        "👌": ["ok", "okay", "perfect", "alright"],
        "✅": ["ok", "okay", "check", "yes", "done"],
        "❌": ["x", "no", "wrong", "cancel"],
        "👍": ["thumbs", "up", "like", "yes", "approve"],
        "👎": ["thumbs", "down", "dislike", "no"],
        "🙏": ["pray", "thanks", "please", "praying"],
        "💪": ["strong", "muscle", "flex"],
        "👏": ["clap", "applause", "bravo"],
        "🎉": ["party", "celebrate", "congrats", "tada"],
        "🎊": ["party", "celebrate", "confetti"],
        "😎": ["cool", "sunglasses", "shades"],
        "🤔": ["think", "thinking", "hmm"],
        "😴": ["sleep", "sleeping", "tired", "zzz"],
        "🥱": ["yawn", "tired", "bored"],
        "🙄": ["eyeroll", "annoyed", "whatever"],
        "😤": ["mad", "angry", "frustrated", "huff"],
        "😡": ["mad", "angry", "rage", "furious"],
        "🤬": ["mad", "angry", "swear", "curse"],
        "🥺": ["please", "pleading", "puppy", "beg"],
        "🤯": ["mind", "blown", "shocked", "wow"],
        "💀": ["dead", "skull", "rip", "ded"],
        "☠️": ["dead", "skull", "danger", "poison"],
        "🤡": ["clown", "joke", "fool"],
        "👻": ["ghost", "boo", "spooky"],
        "🎃": ["halloween", "pumpkin", "spooky"],
        "💩": ["poop", "shit", "crap"],
        "🚀": ["rocket", "launch", "moon"],
        "⚡": ["lightning", "zap", "bolt", "fast"],
        "💯": ["100", "hundred", "perfect", "score"],
        "✨": ["sparkle", "sparkles", "shine", "magic"],
        "🌟": ["star", "shine", "glow"],
        "👀": ["eyes", "look", "watching", "shifty"],
        "💸": ["money", "cash", "fly"],
        "💰": ["money", "bag", "cash"],
        "🍑": ["peach", "butt", "ass"],
        "🍆": ["eggplant", "aubergine"],
        "🥹": ["happy", "tear", "emotional", "moved"]
    ]

    /// Reverse index used by `searchEmojis`. Built once on first access so
    /// "lol" → 😂 / 🤣 lookups don't iterate the alias map.
    static let emojisByAlias: [String: [String]] = {
        var map: [String: [String]] = [:]
        for (emoji, aliases) in keywordAliases {
            for alias in aliases {
                map[alias, default: []].append(emoji)
            }
        }
        return map
    }()

    /// Returns every emoji whose Unicode name OR alias matches `query`
    /// (case-insensitive substring match). Empty query returns an empty
    /// list — callers should short-circuit and show the categorized view
    /// instead. Alias matches are returned first so a search for "lol"
    /// surfaces 😂 / 🤣 ahead of every "face" emoji whose Unicode name
    /// happens to contain those three letters.
    static func searchEmojis(_ query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        var seen = Set<String>()
        var ordered: [String] = []
        for (alias, emojis) in emojisByAlias where alias.contains(q) {
            for emoji in emojis where seen.insert(emoji).inserted {
                ordered.append(emoji)
            }
        }
        for emoji in allEmojis where (nameByEmoji[emoji] ?? "").contains(q) {
            if seen.insert(emoji).inserted { ordered.append(emoji) }
        }
        return ordered
    }
}
