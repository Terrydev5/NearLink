package com.terrydev.nearlink

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Android
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Devices
import androidx.compose.material.icons.filled.IosShare
import androidx.compose.material.icons.filled.LaptopMac
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.AudioFile
import androidx.compose.material.icons.filled.Photo
import androidx.compose.material.icons.filled.PhoneIphone
import androidx.compose.material.icons.filled.Send
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.text.DateFormat
import java.util.Date

private val NearLinkBlue = Color(0xFF147EF5)
private val NearLinkBackground = Color(0xFFF6F7FB)
private val NearLinkSecondaryText = Color(0xFF737985)

class MainActivity : ComponentActivity() {
    private val model by viewModels<NearLinkViewModel>()
    private val nearbyPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        if (granted) model.start()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            val fileLauncher = rememberLauncherForActivityResult(
                ActivityResultContracts.OpenDocument()
            ) { uri -> uri?.let(model::stageFile) }
            val context = LocalContext.current

            NearLinkTheme {
                NearLinkScreen(
                    model = model,
                    chooseFile = { fileLauncher.launch(arrayOf("*/*")) },
                    openFile = { uri, mimeType ->
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, mimeType ?: "*/*")
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        runCatching { context.startActivity(intent) }
                            .onFailure { Toast.makeText(context, "No app can open this file", Toast.LENGTH_SHORT).show() }
                    }
                )
            }
        }
        requestNearbyPermissionIfNeeded()
    }

    private fun requestNearbyPermissionIfNeeded() {
        val permission = if (Build.VERSION.SDK_INT >= 33) {
            Manifest.permission.NEARBY_WIFI_DEVICES
        } else {
            Manifest.permission.ACCESS_FINE_LOCATION
        }
        if (checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED) {
            nearbyPermissionLauncher.launch(permission)
        } else {
            model.start()
        }
    }
}

@Composable
private fun NearLinkTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = lightColorScheme(
            primary = NearLinkBlue,
            background = NearLinkBackground,
            surface = Color.White,
            onBackground = Color(0xFF111318),
            onSurface = Color(0xFF111318)
        ),
        content = content
    )
}

@Composable
private fun NearLinkScreen(
    model: NearLinkViewModel,
    chooseFile: () -> Unit,
    openFile: (Uri, String?) -> Unit
) {
    var openedDevice by remember { mutableStateOf<NearbyDevice?>(null) }

    if (openedDevice == null) {
        NearbyHomeScreen(
            model = model,
            onDeviceSelected = { device ->
                model.selectDevice(device)
                openedDevice = device
            }
        )
    } else {
            ConversationScreen(
                model = model,
                device = openedDevice!!,
                chooseFile = chooseFile,
                openFile = openFile,
                onBack = {
                    model.clearSelectedDevice()
                    openedDevice = null
                }
            )
    }
}

@Composable
private fun NearbyHomeScreen(
    model: NearLinkViewModel,
    onDeviceSelected: (NearbyDevice) -> Unit
) {
    Scaffold(
        contentWindowInsets = WindowInsets.safeDrawing,
        containerColor = NearLinkBackground
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding),
            contentPadding = PaddingValues(start = 20.dp, top = 18.dp, end = 20.dp, bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            item {
                Text("NearLink", fontSize = 38.sp, fontWeight = FontWeight.Bold, letterSpacing = (-1).sp)
            }
            item { LocalDeviceCard(model.localDeviceName) }
            item {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("Nearby devices", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
                    Text(model.discoveryStatus.value, style = MaterialTheme.typography.bodyMedium, color = NearLinkSecondaryText)
                }
            }
            if (model.devices.isEmpty()) {
                item { NearbyEmptyCard() }
            } else {
                items(model.devices, key = { it.id }) { device ->
                    DeviceCard(
                        device = device,
                        preview = model.conversationPreview(device.id),
                        onClick = { onDeviceSelected(device) }
                    )
                }
            }
        }
    }
}

@Composable
private fun LocalDeviceCard(name: String) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(24.dp),
        colors = CardDefaults.cardColors(containerColor = NearLinkBlue),
        elevation = CardDefaults.cardElevation(defaultElevation = 2.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 16.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Surface(shape = RoundedCornerShape(16.dp), color = Color.White.copy(alpha = 0.18f)) {
                Icon(Icons.Default.Android, contentDescription = null, tint = Color.White, modifier = Modifier.padding(12.dp).size(28.dp))
            }
            Spacer(Modifier.width(14.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text("This device", color = Color.White.copy(alpha = 0.8f), style = MaterialTheme.typography.labelLarge)
                Text(name, color = Color.White, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(8.dp).clip(CircleShape).background(Color(0xFF42D66B)))
                    Spacer(Modifier.width(6.dp))
                    Text("Ready to receive", color = Color.White.copy(alpha = 0.85f), style = MaterialTheme.typography.bodyMedium)
                }
            }
        }
    }
}

@Composable
private fun NearbyEmptyCard() {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(24.dp),
        colors = CardDefaults.cardColors(containerColor = Color.White)
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(vertical = 44.dp, horizontal = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Icon(Icons.Default.Devices, contentDescription = null, tint = NearLinkBlue, modifier = Modifier.size(36.dp))
            Text("No nearby devices", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            Text("Keep Wi‑Fi enabled and open NearLink on another device.", color = NearLinkSecondaryText)
        }
    }
}

@Composable
private fun DeviceCard(
    device: NearbyDevice,
    preview: ConversationPreview?,
    onClick: () -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick),
        shape = RoundedCornerShape(24.dp),
        colors = CardDefaults.cardColors(containerColor = Color.White),
        elevation = CardDefaults.cardElevation(defaultElevation = 1.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(16.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            DeviceIcon(device.platform, device.name)
            Spacer(Modifier.width(14.dp))
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(device.name, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (preview == null) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.size(8.dp).clip(CircleShape).background(Color(0xFF35C759)))
                        Spacer(Modifier.width(6.dp))
                        Text(platformName(device), style = MaterialTheme.typography.bodyMedium, color = NearLinkSecondaryText)
                        Text(" · Available", style = MaterialTheme.typography.bodyMedium, color = NearLinkSecondaryText)
                    }
                } else {
                    Text(
                        preview.text,
                        style = MaterialTheme.typography.bodyMedium,
                        color = NearLinkSecondaryText,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
            }
            Column(
                horizontalAlignment = Alignment.End,
                verticalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                if (preview != null) {
                    Text(
                        formatConversationTime(preview.timestamp),
                        style = MaterialTheme.typography.labelSmall,
                        color = NearLinkSecondaryText
                    )
                }
                if ((preview?.unreadCount ?: 0) > 0) {
                    Surface(shape = CircleShape, color = Color(0xFFFF3B30)) {
                        Text(
                            unreadBadgeText(preview!!.unreadCount),
                            modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
                            color = Color.White,
                            style = MaterialTheme.typography.labelSmall,
                            fontWeight = FontWeight.Bold
                        )
                    }
                } else {
                    Text("›", fontSize = 30.sp, color = Color(0xFFB7BAC2))
                }
            }
        }
    }
}

private fun formatConversationTime(timestamp: Long): String =
    DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(timestamp))

private fun unreadBadgeText(count: Int): String = if (count > 99) "99+" else count.toString()

@Composable
private fun DeviceIcon(platform: String, name: String) {
    val normalized = platform.lowercase()
    val icon = when {
        normalized.contains("mac") -> Icons.Default.LaptopMac
        normalized.contains("ios") || normalized.contains("iphone") -> Icons.Default.PhoneIphone
        normalized.contains("android") || name.lowercase().contains("android") -> Icons.Default.Android
        else -> Icons.Default.Devices
    }
    Surface(shape = RoundedCornerShape(16.dp), color = NearLinkBlue.copy(alpha = 0.11f)) {
        Icon(icon, contentDescription = null, tint = NearLinkBlue, modifier = Modifier.padding(12.dp).size(28.dp))
    }
}

private fun platformName(device: NearbyDevice): String {
    val normalized = device.platform.lowercase()
    return when {
        normalized.contains("mac") -> "macOS"
        normalized.contains("ios") || normalized.contains("iphone") -> "iOS"
        normalized.contains("android") || device.name.lowercase().contains("android") -> "Android"
        else -> "NearLink device"
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ConversationScreen(
    model: NearLinkViewModel,
    device: NearbyDevice,
    chooseFile: () -> Unit,
    openFile: (Uri, String?) -> Unit,
    onBack: () -> Unit
) {
    val focusManager = LocalFocusManager.current
    val listState = rememberLazyListState()
    val timeline = model.timeline.filter { it.peerID == device.id }

    LaunchedEffect(timeline.size) {
        val lastIndex = listState.layoutInfo.totalItemsCount - 1
        if (lastIndex >= 0) listState.animateScrollToItem(lastIndex)
    }

    Scaffold(
        contentWindowInsets = WindowInsets.safeDrawing,
        containerColor = NearLinkBackground,
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(device.name, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(platformName(device), style = MaterialTheme.typography.labelMedium, color = NearLinkSecondaryText)
                    }
                },
                navigationIcon = {
                    IconButton(onClick = onBack) { Icon(Icons.Default.ArrowBack, contentDescription = "Back") }
                },
                actions = {
                    AssistChip(
                        onClick = {},
                        label = { Text("Available") },
                        leadingIcon = { Box(Modifier.size(8.dp).clip(CircleShape).background(Color(0xFF35C759))) }
                    )
                }
            )
        },
        bottomBar = {
            MessageComposer(
                text = model.draft.value,
                onTextChanged = { model.draft.value = it },
                canSend = model.selectedDevice.value != null && model.draft.value.isNotBlank(),
                onChooseFile = chooseFile,
                onSend = {
                    model.send()
                    focusManager.clearFocus()
                },
                onDone = { focusManager.clearFocus() }
            )
        }
    ) { padding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .pointerInput(Unit) { detectTapGestures { focusManager.clearFocus() } }
        ) {
            if (timeline.isEmpty()) {
                ConversationEmpty(device.name)
            } else {
                LazyColumn(
                    state = listState,
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(horizontal = 16.dp, vertical = 14.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    items(timeline, key = { it.id }) { item ->
                        when (item) {
                            is ConversationItem.Message -> MessageBubble(item)
                            is ConversationItem.Transfer -> {
                                model.transfers[item.transferID]?.let { transfer ->
                                    TransferCard(
                                        transfer = transfer,
                                        onOpen = { uri -> openFile(uri, transfer.mimeType) },
                                        onAccept = { model.acceptIncoming(transfer.id) },
                                        onReject = { model.rejectIncoming(transfer.id) }
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ConversationEmpty(deviceName: String) {
    Column(
        modifier = Modifier.fillMaxSize().padding(28.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Icon(Icons.Default.IosShare, contentDescription = null, tint = NearLinkBlue, modifier = Modifier.size(42.dp))
        Spacer(Modifier.height(12.dp))
        Text("Start a conversation", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
        Text("Send a message or attach a file to $deviceName.", color = NearLinkSecondaryText)
    }
}

@Composable
private fun MessageBubble(message: ConversationItem.Message) {
    if (message.system) {
        Text(
            message.text,
            modifier = Modifier.fillMaxWidth(),
            color = NearLinkSecondaryText,
            style = MaterialTheme.typography.bodySmall
        )
        return
    }

    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = if (message.outgoing) Arrangement.End else Arrangement.Start
    ) {
        Surface(
            color = if (message.outgoing) NearLinkBlue else Color.White,
            shape = RoundedCornerShape(18.dp),
            shadowElevation = if (message.outgoing) 0.dp else 1.dp
        ) {
            Text(
                message.text,
                modifier = Modifier.padding(horizontal = 15.dp, vertical = 10.dp),
                color = if (message.outgoing) Color.White else Color(0xFF17181B),
                style = MaterialTheme.typography.bodyLarge
            )
        }
    }
}

@Composable
private fun TransferCard(
    transfer: TransferItem,
    onOpen: (Uri) -> Unit,
    onAccept: () -> Unit,
    onReject: () -> Unit
) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .then(
                if (transfer.status == TransferStatus.COMPLETED && transfer.localUri != null) {
                    Modifier.clickable { onOpen(transfer.localUri) }
                } else {
                    Modifier
                }
            ),
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(containerColor = Color.White)
    ) {
        Column(modifier = Modifier.fillMaxWidth().padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
            Surface(shape = RoundedCornerShape(14.dp), color = NearLinkBlue.copy(alpha = 0.12f)) {
                    Icon(
                        transferIcon(transfer.mimeType),
                        contentDescription = null,
                        tint = NearLinkBlue,
                        modifier = Modifier.padding(12.dp).size(28.dp)
                    )
            }
            Spacer(Modifier.width(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(transfer.fileName, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(formatBytes(transfer.fileSize), style = MaterialTheme.typography.bodySmall, color = NearLinkSecondaryText)
            }
            Text(transferStatusTitle(transfer), style = MaterialTheme.typography.labelLarge, color = transferStatusColor(transfer))
            }
            LinearProgressIndicator(
                progress = { transfer.progress },
                modifier = Modifier.fillMaxWidth(),
                color = transferStatusColor(transfer),
                trackColor = Color(0xFFE1E3E8)
            )
            if (transfer.incoming && transfer.status == TransferStatus.WAITING) {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Button(onClick = onReject) { Text("Decline") }
                    Button(onClick = onAccept) { Text("Accept") }
                }
            }
            if (transfer.status == TransferStatus.COMPLETED && transfer.localUri != null) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Default.IosShare, contentDescription = null, tint = NearLinkSecondaryText, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Tap to preview", color = NearLinkSecondaryText, style = MaterialTheme.typography.bodySmall)
                }
            }
        }
    }
}

private fun transferIcon(mimeType: String?) = when {
    mimeType?.startsWith("image/") == true -> Icons.Default.Photo
    mimeType?.startsWith("video/") == true -> Icons.Default.Movie
    mimeType?.startsWith("audio/") == true -> Icons.Default.AudioFile
    else -> Icons.Default.Description
}

private fun transferStatusTitle(transfer: TransferItem): String = when (transfer.status) {
    TransferStatus.WAITING -> if (transfer.incoming) "Accept?" else "Waiting…"
    TransferStatus.SENDING -> "Sending…"
    TransferStatus.RECEIVING -> "Receiving…"
    TransferStatus.COMPLETED -> if (transfer.incoming) "Saved" else "Completed"
    TransferStatus.FAILED -> "Failed"
    TransferStatus.CANCELLED -> "Cancelled"
}

private fun transferStatusColor(transfer: TransferItem): Color = when (transfer.status) {
    TransferStatus.COMPLETED -> Color(0xFF2DBE60)
    TransferStatus.FAILED -> Color(0xFFE5484D)
    TransferStatus.CANCELLED -> NearLinkSecondaryText
    TransferStatus.SENDING, TransferStatus.RECEIVING -> NearLinkBlue
    TransferStatus.WAITING -> NearLinkSecondaryText
}

private fun formatBytes(bytes: Long): String {
    if (bytes < 1024) return "$bytes B"
    val units = arrayOf("KB", "MB", "GB", "TB")
    var value = bytes.toDouble()
    var unit = 0
    while (value >= 1024 && unit < units.lastIndex) {
        value /= 1024
        unit++
    }
    return if (value >= 10 || value % 1.0 == 0.0) "%.0f %s".format(value, units[unit]) else "%.1f %s".format(value, units[unit])
}

@Composable
private fun MessageComposer(
    text: String,
    onTextChanged: (String) -> Unit,
    canSend: Boolean,
    onChooseFile: () -> Unit,
    onSend: () -> Unit,
    onDone: () -> Unit
) {
    Surface(
        modifier = Modifier.navigationBarsPadding().imePadding(),
        color = Color.White,
        shadowElevation = 8.dp,
        tonalElevation = 2.dp
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.Bottom,
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            IconButton(onClick = onChooseFile) {
                Icon(Icons.Default.AttachFile, contentDescription = "Attach file", tint = NearLinkBlue)
            }
            TextField(
                value = text,
                onValueChange = onTextChanged,
                modifier = Modifier.weight(1f),
                placeholder = { Text("Write a message", color = NearLinkSecondaryText) },
                maxLines = 4,
                shape = RoundedCornerShape(24.dp),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { onDone() }),
                colors = TextFieldDefaults.colors(
                    focusedContainerColor = Color(0xFFF0F1F4),
                    unfocusedContainerColor = Color(0xFFF0F1F4),
                    disabledContainerColor = Color(0xFFF0F1F4),
                    focusedIndicatorColor = Color.Transparent,
                    unfocusedIndicatorColor = Color.Transparent
                )
            )
            IconButton(onClick = onSend, enabled = canSend) {
                Surface(shape = CircleShape, color = if (canSend) NearLinkBlue else Color(0xFFD1D3D8)) {
                    Icon(Icons.Default.Send, contentDescription = "Send message", tint = Color.White, modifier = Modifier.padding(11.dp).size(20.dp))
                }
            }
        }
    }
}
