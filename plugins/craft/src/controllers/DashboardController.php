<?php

declare(strict_types=1);

namespace Runlight\Craft\controllers;

use craft\web\Controller;
use Runlight\Craft\Plugin;
use yii\web\Response;

/** The Control Panel's Runlight item: opens the dashboard, which lives in your Runlight. */
final class DashboardController extends Controller
{
    public function actionIndex(): Response
    {
        $this->requirePermission('accessPlugin-runlight');
        $address = Plugin::getInstance()->getSettings()->getAddress();
        if ($address === '') {
            return $this->redirect('settings/plugins/runlight');
        }
        return $this->redirect($address . '/');
    }
}
