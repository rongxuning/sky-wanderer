package com.rongxuning.skywanderer.ui

import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Place
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.navigation.NavDestination.Companion.hierarchy
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.rongxuning.skywanderer.R
import com.rongxuning.skywanderer.ui.auth.AuthScreen
import com.rongxuning.skywanderer.ui.home.HomeScreen
import com.rongxuning.skywanderer.ui.me.MeScreen
import com.rongxuning.skywanderer.ui.records.RecordsScreen
import com.rongxuning.skywanderer.ui.routes.RoutesScreen
import com.rongxuning.skywanderer.ui.theme.OmniCanvas
import com.rongxuning.skywanderer.ui.training.TrainingScreen

object AppRoute {
    const val Home = "home"
    const val Auth = "auth"
    const val Records = "records"
    const val Training = "training"
    const val Paths = "routes"
    const val Me = "me"
}

private data class Tab(val route: String, val label: Int, val icon: ImageVector)

private val tabs = listOf(
    Tab(AppRoute.Home, R.string.tab_home, Icons.Filled.Home),
    Tab(AppRoute.Records, R.string.tab_records, Icons.AutoMirrored.Filled.List),
    Tab(AppRoute.Training, R.string.tab_training, Icons.Filled.Star),
    Tab(AppRoute.Paths, R.string.tab_routes, Icons.Filled.Place),
    Tab(AppRoute.Me, R.string.tab_me, Icons.Filled.Person),
)

@Composable
fun SkyWandererRoot(navController: NavHostController = rememberNavController()) {
    val backStack by navController.currentBackStackEntryAsState()
    val destination = backStack?.destination
    val showTabs = destination?.route != AppRoute.Auth

    Scaffold(
        containerColor = OmniCanvas,
        bottomBar = {
            if (showTabs) {
                NavigationBar(containerColor = Color.White) {
                    tabs.forEach { tab ->
                        val label = stringResource(tab.label)
                        val selected = destination?.hierarchy?.any { it.route == tab.route } == true
                        NavigationBarItem(
                            selected = selected,
                            onClick = {
                                navController.navigate(tab.route) {
                                    popUpTo(navController.graph.findStartDestination().id) {
                                        saveState = true
                                    }
                                    launchSingleTop = true
                                    restoreState = true
                                }
                            },
                            icon = { Icon(tab.icon, contentDescription = label) },
                            label = { Text(label) },
                        )
                    }
                }
            }
        },
    ) { padding ->
        NavHost(
            navController = navController,
            startDestination = AppRoute.Home,
            modifier = Modifier.padding(padding),
        ) {
            composable(AppRoute.Home) {
                HomeScreen(onSignIn = { navController.navigate(AppRoute.Auth) })
            }
            composable(AppRoute.Auth) {
                AuthScreen(onBack = { navController.popBackStack() })
            }
            composable(AppRoute.Records) { RecordsScreen() }
            composable(AppRoute.Training) { TrainingScreen() }
            composable(AppRoute.Paths) { RoutesScreen() }
            composable(AppRoute.Me) { MeScreen() }
        }
    }
}
