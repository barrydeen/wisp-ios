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

    /// Supplemental keyword aliases for terms the Unicode CLDR keyword
    /// data (loaded by `CldrEmojiKeywords`) genuinely doesn't ship.
    /// CLDR already covers the standard descriptions (love, fire, laugh,
    /// thumbs, etc.) AND most slang (lol, lmao, lit, ily, etc.), so this
    /// table is intentionally small — only the nostr-culture, internet
    /// shorthand, and explicit-override entries that aren't in CLDR's
    /// English annotations.
    ///
    /// When extending: check `CldrEmojiKeywords.keywordsByEmoji[e]` first
    /// to avoid duplicating coverage.
    static let keywordAliases: [String: [String]] = [
        // Internet slang / shorthand not in CLDR
        "💀": ["ded"],
        "😏": ["sus", "suspicious"],
        "🤨": ["sus", "suspicious"],
        "🥹": ["pleading"],
        // Nostr-culture
        "🐸": ["pepe"],
        // Useful overrides where the CLDR keyword set is sparse or where
        // we want the alias to rank ahead of unrelated Unicode-name hits
        "✅": ["ok", "yes"],
        "❌": ["x", "no"],
        "🚀": ["moon", "fly"],
        "🔥": ["af"],
        "👀": ["shifty", "watching"],
        // Common short forms
        "💯": ["100", "hundred"],
        "🆗": ["ok"],
        "🆕": ["new"]
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

    /// Returns every emoji whose CLDR keyword, hand-curated alias, or
    /// Unicode name matches `query` (case-insensitive substring match).
    /// Empty query returns an empty list — callers should short-circuit
    /// and show the categorized view instead.
    ///
    /// Match order is deliberate:
    /// 1. Hand-curated `keywordAliases` — covers nostr-culture and slang
    ///    that CLDR doesn't ship ("pepe", "lol", "ded", etc.).
    /// 2. CLDR keywords — the comprehensive 1500-entry index from
    ///    Unicode's official annotations data.
    /// 3. Unicode name substring — last-resort catch-all.
    ///
    /// Filtering to entries that appear in the rendered `allEmojis` set
    /// keeps the catalog as the source of truth — CLDR has many emoji
    /// our categories don't include (e.g. skin-tone modifiers as
    /// standalone entries) which we don't want surfaced as standalone
    /// results.
    static func searchEmojis(_ query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        let renderable = Set(allEmojis)
        var seen = Set<String>()
        var ordered: [String] = []

        for (alias, emojis) in emojisByAlias where alias.contains(q) {
            for emoji in emojis where renderable.contains(emoji) && seen.insert(emoji).inserted {
                ordered.append(emoji)
            }
        }
        for (keyword, emojis) in CldrEmojiKeywords.emojisByKeyword where keyword.contains(q) {
            for emoji in emojis where renderable.contains(emoji) && seen.insert(emoji).inserted {
                ordered.append(emoji)
            }
        }
        for emoji in allEmojis where (nameByEmoji[emoji] ?? "").contains(q) {
            if seen.insert(emoji).inserted { ordered.append(emoji) }
        }
        return ordered
    }
}
