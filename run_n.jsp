<%@page import="org.json.JSONArray"%>
<%@page import="java.io.InputStreamReader"%>
<%@page import="java.io.BufferedReader"%>
<%@page import="java.net.HttpURLConnection"%>
<%@page import="java.net.URL"%>
<%@page import="com.fz.util.FZUtil"%>
<%@page import="org.json.JSONObject"%>
<%@page import="com.fz.tms.service.algo.FZRouteJob"%>
<%@page import="com.fz.tms.service.algoCaller.CostDistSetter"%>
<%@page import="com.fz.tms.service.algo.FZDeliveryAgent"%>
<%@page import="java.util.ArrayList"%>
<%@page import="com.fz.tms.service.algo.FZCustDelivery"%>
<%@page import="java.util.List"%>
<%@page import="java.sql.ResultSet"%>
<%@page import="com.fz.tms.service.algo.FZParams"%>
<%@page import="java.sql.PreparedStatement"%>
<%@page import="com.fz.tms.service.algo.FZRouter"%>
<%@page import="com.fz.tms.service.algoCaller.WebEventHandler"%>
<%@page import="com.fz.tms.service.algo.FZAlgoContext"%>
<%@page import="com.fz.tms.service.algoCaller.Db"%>
<%@page import="java.sql.Connection"%>
<%@page import="com.fz.util.FZVrpUtil"%>
<%!

	Double firstPriority = new Double(0);
    Double secondPriority = new Double(0);
	int maxDestInAPI = 0;
	
    public String run(HttpServletRequest request, HttpServletResponse response
            , PageContext pc
    ) {
        
        final String conName = "jdbc/fztms";
        String result = "OK";
        try {
			getParams();
            // get runID param
            String runID = FZVrpUtil.getHttpParam(request, "runID");
            FZAlgoContext cx = new FZAlgoContext();
            cx.runID = runID;

            String dateDeliv = FZVrpUtil.getHttpParam(request, "dateDeliv");
            cx.log("RunID = " + runID 
                + ", Deliv date = " + dateDeliv
            );

            // prepare param placeholders
            String branchCode = "";
            String shift = "";
            String tripCalc = "";
            int maxIter = 0;
            
            // prepare sql to get params
            String sql = "select branch, shift, tripCalc, maxIter"
                    + " from bosnet1.dbo.TMS_Progress"
                    + " where runID = '" + runID + "'"
                    + " and status = 'NEW'";

            cx.log("Get run record = " + sql); 

            // open db con
            try (Connection con = (new Db()).getConnection(conName);
                    java.sql.PreparedStatement ps 
                        = con.prepareStatement(sql)) {
                
//                ps.setString(1, runID);
//                ps.setString(2, "NEW");

                // begin transaction
                cx.log("Begin trans"); 
                con.setAutoCommit(false);
                
                // read run request in progress table
                try (java.sql.ResultSet rs = ps.executeQuery()){

                    // if has rows, get the param
                    if (rs.next()){

                        cx.log("has rows, updating to INPG"); 
                        
                        // update progress status as INPR, release transaction
                        updateStatusAsInProgress(runID, con);
                        con.setAutoCommit(true);
                        
                        // get the params
                        branchCode = FZVrpUtil.getRsString(rs, 1, "");
                        shift = FZVrpUtil.getRsString(rs, 2, "");
                        tripCalc = FZVrpUtil.getRsString(rs, 3, "");
                        maxIter = FZVrpUtil.getRsInt(rs, 4, 50);
                        
                        cx.log("Branch: " + branchCode 
                            + ", shift " + shift 
                            + ", tripCalc " + tripCalc
                            + ", maxIter " + maxIter
                        ); 
                    }
                    else { // else
                        
                        // release transaction
                        con.setAutoCommit(true);
                        
                        // set result = cannot find runID
                        result = "Cannot find runID = " + runID;
                    }
                }

                // if not OK, return
                if (!result.equals("OK")) return result;

                cx.log("Contruct Algo Context");

                // reach here means db read OK
                cx.params = readParams(con);

                cx.custDeliveries = readCustDeliveries(
                        runID, branchCode, dateDeliv, shift, con, cx);

                cx.deliveryAgents = readDeliveryAgents(
                        runID, branchCode, dateDeliv, shift, con, cx);
				
                cx.algoEventHandler = new WebEventHandler(cx);
                cx.maxIteration = cx.params.getInt("MaxIteration");
                cx.saveToDbFreq = cx.params.getInt("UpdateToDbFreq");
                cx.timeDistSource = tripCalc; //"G";
                cx.workFolder = cx.params.get("WorkingFolder");
                
                cx.prevCostDistRunID = "";
                cx.branchCode = branchCode;
                cx.shift = shift;
                cx.folderForLog = "c:\\fza\\log\\";

                cx.firstPriorityUnassignedPenalty = firstPriority;//9123456
                cx.secondPriorityUnassignedPenalty = secondPriority //0.2 
                    * cx.firstPriorityUnassignedPenalty;

                cx.log("Getting cost dist");
                getCostDist(cx, con);
                cx.log("Cost dist count: " + cx.costDists.size());

                cx.log("Calling router run");
                FZRouter.run(cx);

                // write to db
                cx.log("Writing output"
                    + ", routeJobs: " + cx.routeJobs.size()
                    + ", unAsgJobs: " + cx.unAsgJobs.size()
                );
                writeOutputRouteJobs(cx);
            }

        } catch(Exception e) {
            result = FZVrpUtil.toStackTraceText(e);
        }
        return result;
    }
	
	public void getParams() throws Exception{
        String sql = "SELECT\n" +
                "	pa.value,\n" +
                "	ps.value,\n" +
				"	pd.value\n" +
                "FROM\n" +
                "	BOSNET1.dbo.TMS_Params pa\n" +
                "LEFT OUTER JOIN BOSNET1.dbo.TMS_Params ps ON\n" +
                "	ps.param = 'secondPriorityUnassignedPenalty'\n" +
				"LEFT OUTER JOIN BOSNET1.dbo.TMS_Params pd ON\n" +
                "	pd.param = 'maxDestInAPI'\n" +
                "WHERE\n" +
                "	pa.param = 'firstPriorityUnassignedPenalty';";
				System.out.println(sql);
        try (Connection con = (new Db()).getConnection("jdbc/fztms");
                PreparedStatement ps = con.prepareStatement(sql)){

            try (ResultSet rs = ps.executeQuery()){
                while (rs.next()) {
                    int i = 1;
                    firstPriority = Double.parseDouble(FZUtil.getRsString(rs, i++, ""));
                    secondPriority = Double.parseDouble(FZUtil.getRsString(rs, i++, ""));
					maxDestInAPI = Integer.parseInt(FZUtil.getRsString(rs, i++, ""));
                }
            }
            //System.out.println(firstPriority * secondPriority);
        } 
    }

    private String addMinutesIfAbove(
            String clock, int above, int add) throws Exception {

        // skip if clock empty
        if (clock.length() == 0) return "";

        // convert clock to min
        int time = FZVrpUtil.clockToMin(clock);

        // if above given time
        if (time > above){

            // add the minutes
            int newTime = time + add;
            return FZVrpUtil.toClock(newTime);
        }
        else {
            // else dont add
            return clock;
        }
    }
    
    private void addBreakTimes(FZAlgoContext cx, FZRouteJob j) 
        throws Exception {

        // TODO
        // if delivDate is Friday 
            // add 1.5 hour
        // else
            j.arrive = addMinutesIfAbove(j.arrive, 720, 60);
            j.depart = addMinutesIfAbove(j.depart, 720, 60);
    }

    private void addDist(FZAlgoContext cx, FZRouteJob j, FZRouteJob prevJ) 
        throws Exception {
        
        // find distance from prevJ to this J
        // loop thru costDists (list of dist & dur of each lon lat permutation)
        JSONObject foundCostDist = null;
        for (JSONObject costDist : cx.costDists){
            
//            String cost1SiteID = costDist.getString("from");
//            String cost2SiteID = costDist.getString("to");
//            if (
//                (cost1SiteID.equals(prevSiteID))
//                && 
//                (cost2SiteID.equals(j.siteID))
//                 ){
//                foundCostDist = costDist;
//                break;
//            }

//            String site1Lon = costDist.getString("lon1");
//            String site1Lat = costDist.getString("lat1");
//            String site2Lon = costDist.getString("lon2");
//            String site2Lat = costDist.getString("lat2");
//
//            if (
//                (site1Lon.equals(prevJ.lon))
//                && 
//                (site1Lat.equals(prevJ.lat))
//                && 
//                (site2Lon.equals(j.lon))
//                && 
//                (site2Lat.equals(j.lat))
//                 ){
//                foundCostDist = costDist;
//                break;
//            }

            double site1Lon = Double.parseDouble(costDist.getString("lon1"));
            double site1Lat = Double.parseDouble(costDist.getString("lat1"));
            double site2Lon = Double.parseDouble(costDist.getString("lon2"));
            double site2Lat = Double.parseDouble(costDist.getString("lat2"));

            double prevJLon = Double.parseDouble(prevJ.lon);
            double prevJLat = Double.parseDouble(prevJ.lat);
            double curJLon = Double.parseDouble(j.lon);
            double curJLat = Double.parseDouble(j.lat);

            if (
                (site1Lon == prevJLon)
                && 
                (site1Lat == prevJLat)
                && 
                (site2Lon == curJLon)
                && 
                (site2Lat == curJLat)
                 ){
                foundCostDist = costDist;
                break;
            }

        }
        if (foundCostDist != null){
            j.dist = foundCostDist.getDouble("dist");
        }
        else{
            j.dist = 0;
        }
    }

    private void writeOutputRouteJobs(FZAlgoContext cx) throws Exception {

        // save to db
        String sql = "insert into bosnet1.dbo.TMS_RouteJob("
            + "job_id"
            + ", customer_id"
            + ", do_number"
            + ", vehicle_code"
            + ", activity"
            + ", routeNb"
            + ", jobNb"
            + ", arrive"
            + ", depart"
            + ", runID"
            + ", create_dtm"
            + ", branch"
            + ", shift"
            + ", lon"
            + ", lat"
            + ", weight"
            + ", volume"
            + ", transportCost"
            + ", activityCost"
            + ", dist"
            + ") values(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
        ;
        
        try (Connection con = (new Db()).getConnection("jdbc/fztms")){

            try (PreparedStatement ps = con.prepareStatement(sql) ){
                
                // routed jobs
                FZRouteJob prevJ = null;
                for (FZRouteJob j : cx.routeJobs){

                    // if not first job
                    if (j.arrive.length() > 0) {

                        // add break 
                        addBreakTimes(cx, j);

                        // set distance
                        addDist(cx, j, prevJ);
                    }

                    // set current job as previous job for next loop
                    prevJ = j;

                    // prepare insert to db
                    ps.clearParameters();

                    int i = 1;
                    ps.setString(i++, j.siteID);
                    ps.setString(i++, j.custID);
                    ps.setString(i++, j.DONum);
                    ps.setString(i++, j.vehicleCode);
                    ps.setString(i++, j.activity);
					
					//+1 last depo jobNb
					if(j.siteID == "DEPO" && j.depart == ""){
						j.jobNb = j.jobNb + 1;
					}
					
                    ps.setInt(i++, j.routeNb);
                    ps.setInt(i++, j.jobNb);
                    ps.setString(i++, j.arrive);
                    ps.setString(i++, j.depart);
                    ps.setString(i++, j.runID);
                    ps.setString(i++, FZVrpUtil.getCurTime());
                    ps.setString(i++, j.branch);
                    ps.setString(i++, j.shift);
                    ps.setString(i++, j.lon);
                    ps.setString(i++, j.lat);
                    ps.setString(i++, j.weight);
                    ps.setString(i++, j.volume);
                    ps.setDouble(i++, j.transportCost);
                    ps.setDouble(i++, j.activityCost);
                    ps.setDouble(i++, j.dist);

                    ps.addBatch();
                }
                
                // unasg jobs
                for (FZRouteJob j : cx.unAsgJobs){

                    ps.clearParameters();

                    int i = 1;
                    ps.setString(i++, j.siteID);
                    ps.setString(i++, j.custID);
                    ps.setString(i++, j.DONum);
                    ps.setString(i++, j.vehicleCode); 
                    ps.setString(i++, j.activity);
                    ps.setInt(i++, j.routeNb); 
                    ps.setInt(i++, j.jobNb);
                    ps.setString(i++, j.arrive);
                    ps.setString(i++, j.depart);
                    ps.setString(i++, j.runID);
                    ps.setString(i++, FZVrpUtil.getCurTime());
                    ps.setString(i++, j.branch);
                    ps.setString(i++, j.shift);
                    ps.setString(i++, j.lon);
                    ps.setString(i++, j.lat);
                    ps.setString(i++, j.weight);
                    ps.setString(i++, j.volume);
                    ps.setDouble(i++, j.transportCost);
                    ps.setDouble(i++, j.activityCost);
                    ps.setDouble(i++, j.dist);

                    ps.addBatch();
                }
                ps.executeBatch();

                ((WebEventHandler) cx.algoEventHandler)
                    .updateProgressInDb(con, "Done", 100, "DONE");
            }
        }
    }

    private void updateStatusAsInProgress(String runID
            , Connection con) throws Exception {
        
        String sql = "update bosnet1.dbo.TMS_Progress"
                + " set status = 'INPR'"
                + " where runID = '" + runID + "'"
                ;
        try (PreparedStatement ps = con.prepareStatement(sql)){
//            ps.setString(1, "INPR");
//            ps.setString(2, runID);
            ps.executeUpdate();
        }
    }

    private FZParams readParams(Connection con) throws Exception {
        FZParams params = new FZParams();
        String sql = "select param, value from bosnet1.dbo.TMS_Params";
        try (PreparedStatement ps = con.prepareStatement(sql);
                ResultSet rs = ps.executeQuery()){
            while (rs.next()){
                params.put(rs.getString(1), rs.getString(2));
            }
        }
        return params;
    }
    static List<FZCustDelivery> readCustDeliveries(String RunId, String branchCode
            , String DelivDate
			, String shift
            , Connection con
            , FZAlgoContext cx) 
            throws Exception {

        //prepareCustTable(branchCode, con);
        
        List<FZCustDelivery> cds = new ArrayList<FZCustDelivery>();
        String sql = /*"select\n" +
				"	a.Customer_ID,\n" +
				"	q.DO_Number,\n" +
				"	a.Long,\n" +
				"	a.Lat,\n" +
				"	q.Customer_priority,\n" +
				"	a.Service_time,\n" +
				"	a.deliv_start,\n" +
				"	a.deliv_end,\n" +
				"	a.vehicle_type_list,\n" +
				"	sum( a.total_kg ) total_kg,\n" +
				"	sum( a.total_cubication ) total_cubication,\n" +
				"	a.DeliveryDeadline,\n" +
				"	a.DayWinStart,\n" +
				"	a.DayWinEnd\n" +
				"from\n" +
				"	BOSNET1.dbo.TMS_PreRouteJob a inner join(\n" +
				"		select\n" +
				"			a.RunId,\n" +
				"			a.customer_id,\n" +
				"			count( a.DO_Number ) DO_Number,\n" +
				"			MIN( Customer_priority ) Customer_priority\n" +
				"		from\n" +
				"			(\n" +
				"				select\n" +
				"					distinct RunId,\n" +
				"					customer_id,\n" +
				"					DO_Number,\n" +
				"					Customer_priority\n" +
				"				from\n" +
				"					BOSNET1.dbo.TMS_PreRouteJob\n" +
				"				where\n" +
				"					isActive = '1'\n" +
				"					and Is_Edit = 'edit'\n" +
				"					and Is_Exclude = 'inc'\n" +
				"			) a\n" +
				"		group by\n" +
				"			a.RunId,\n" +
				"			a.customer_id\n" +
				"	) q on\n" +
				"	a.RunId = q.RunId\n" +
				"	and a.Customer_ID = q.Customer_ID\n" +
				"where\n" +
				"	a.RunId = '" + cx.runID + "'\n" +
				"	and a.isActive = '1'\n" +
				"	and a.Is_Edit = 'edit'\n" +
				"	and a.Is_Exclude = 'inc'\n" +
				"group by\n" +
				"	a.Customer_ID,\n" +
				"	q.DO_Number,\n" +
				"	a.Long,\n" +
				"	a.Lat,\n" +
				"	q.Customer_priority,\n" +
				"	a.Service_time,\n" +
				"	a.deliv_start,\n" +
				"	a.deliv_end,\n" +
				"	a.vehicle_type_list,\n" +
				"	a.DeliveryDeadline,\n" +
				"	a.DayWinStart,\n" +
				"	a.DayWinEnd;";
				*/
		
				"SELECT\n" +
				"	GroupId AS Customer_ID,\n" +
				"	COUNT( DO_Number ) DO_Number,\n" +
				"	MIN( Long ) Long,\n" +
				"	MIN( Lat ) Lat,\n" +
				"	MIN( Customer_priority ) Customer_priority,\n" +
				"	SUM( Service_time ) Service_time,\n" +
				"	MIN( deliv_start ) deliv_start,\n" +
				"	MAX( deliv_end ) deliv_end,\n" +
				"	MAX( vehicle_type_list ) vehicle_type_list,\n" +
				"	SUM( total_kg ) total_kg,\n" +
				"	SUM( total_cubication ) total_cubication,\n" +
				"	MAX( DeliveryDeadline ) DeliveryDeadline,\n" +
				"	MIN( DayWinStart ) DayWinStart,\n" +
				"	MAX( DayWinEnd ) DayWinEnd\n" +
				"FROM\n" +
				"	(\n" +
				"		SELECT\n" +
				"			a.Customer_ID,\n" +
				"			q.DO_Number,\n" +
				"			a.Long,\n" +
				"			a.Lat,\n" +
				"			q.Customer_priority,\n" +
				"			a.Service_time,\n" +
				"			a.deliv_start,\n" +
				"			a.deliv_end,\n" +
				"			a.vehicle_type_list,\n" +
				"			SUM( a.total_kg ) total_kg,\n" +
				"			SUM( a.total_cubication ) total_cubication,\n" +
				"			a.DeliveryDeadline,\n" +
				"			a.DayWinStart,\n" +
				"			a.DayWinEnd,\n" +
				"			a.GroupId\n" +
				"		FROM\n" +
				"			BOSNET1.dbo.TMS_PreRouteJob a\n" +
				"		INNER JOIN(\n" +
				"				SELECT\n" +
				"					a.RunId,\n" +
				"					a.customer_id,\n" +
				"					COUNT( a.DO_Number ) DO_Number,\n" +
				"					MIN( Customer_priority ) Customer_priority\n" +
				"				FROM\n" +
				"					(\n" +
				"						SELECT\n" +
				"							DISTINCT RunId,\n" +
				"							customer_id,\n" +
				"							DO_Number,\n" +
				"							Customer_priority\n" +
				"						FROM\n" +
				"							BOSNET1.dbo.TMS_PreRouteJob\n" +
				"						WHERE\n" +
				"							isActive = '1'\n" +
				"							AND Is_Edit = 'edit'\n" +
				"							AND Is_Exclude = 'inc'\n" +
				"					) a\n" +
				"				GROUP BY\n" +
				"					a.RunId,\n" +
				"					a.customer_id\n" +
				"			) q ON\n" +
				"			a.RunId = q.RunId\n" +
				"			AND a.Customer_ID = q.Customer_ID\n" +
				"		WHERE\n" +
				"			a.RunId = '" + cx.runID + "'\n" +
				"			AND a.isActive = '1'\n" +
				"			AND a.Is_Edit = 'edit'\n" +
				"			AND a.Is_Exclude = 'inc'\n" +
				"		GROUP BY\n" +
				"			a.Customer_ID,\n" +
				"			q.DO_Number,\n" +
				"			a.Long,\n" +
				"			a.Lat,\n" +
				"			q.Customer_priority,\n" +
				"			a.Service_time,\n" +
				"			a.deliv_start,\n" +
				"			a.deliv_end,\n" +
				"			a.vehicle_type_list,\n" +
				"			a.DeliveryDeadline,\n" +
				"			a.DayWinStart,\n" +
				"			a.DayWinEnd,\n" +
				"			a.GroupId\n" +
				"	) aq\n" +
				"WHERE\n" +
				"	GroupId IS NOT NULL\n" +
				"	AND GroupId > 0\n" +
				"GROUP BY\n" +
				"	GroupId\n" +
				"UNION ALL SELECT\n" +
				"	a.Customer_ID,\n" +
				"	q.DO_Number,\n" +
				"	a.Long,\n" +
				"	a.Lat,\n" +
				"	q.Customer_priority,\n" +
				"	a.Service_time,\n" +
				"	a.deliv_start,\n" +
				"	a.deliv_end,\n" +
				"	a.vehicle_type_list,\n" +
				"	SUM( a.total_kg ) total_kg,\n" +
				"	SUM( a.total_cubication ) total_cubication,\n" +
				"	a.DeliveryDeadline,\n" +
				"	a.DayWinStart,\n" +
				"	a.DayWinEnd\n" +
				"FROM\n" +
				"	BOSNET1.dbo.TMS_PreRouteJob a\n" +
				"INNER JOIN(\n" +
				"		SELECT\n" +
				"			a.RunId,\n" +
				"			a.customer_id,\n" +
				"			COUNT( a.DO_Number ) DO_Number,\n" +
				"			MIN( Customer_priority ) Customer_priority\n" +
				"		FROM\n" +
				"			(\n" +
				"				SELECT\n" +
				"					DISTINCT RunId,\n" +
				"					customer_id,\n" +
				"					DO_Number,\n" +
				"					Customer_priority\n" +
				"				FROM\n" +
				"					BOSNET1.dbo.TMS_PreRouteJob\n" +
				"				WHERE\n" +
				"					isActive = '1'\n" +
				"					AND Is_Edit = 'edit'\n" +
				"					AND Is_Exclude = 'inc'\n" +
				"			) a\n" +
				"		GROUP BY\n" +
				"			a.RunId,\n" +
				"			a.customer_id\n" +
				"	) q ON\n" +
				"	a.RunId = q.RunId\n" +
				"	AND a.Customer_ID = q.Customer_ID\n" +
				"WHERE\n" +
				"	a.RunId = '" + cx.runID + "'\n" +
				"	AND a.isActive = '1'\n" +
				"	AND a.Is_Edit = 'edit'\n" +
				"	AND a.Is_Exclude = 'inc'\n" +
				"	AND(\n" +
				"		GroupId IS NULL\n" +
				"		OR GroupId > 0\n" +
				"	)\n" +
				"	AND(\n" +
				"		GroupId IS NULL\n" +
				"		OR GroupId = 0\n" +
				"	)\n" +
				"GROUP BY\n" +
				"	a.Customer_ID,\n" +
				"	q.DO_Number,\n" +
				"	a.Long,\n" +
				"	a.Lat,\n" +
				"	q.Customer_priority,\n" +
				"	a.Service_time,\n" +
				"	a.deliv_start,\n" +
				"	a.deliv_end,\n" +
				"	a.vehicle_type_list,\n" +
				"	a.DeliveryDeadline,\n" +
				"	a.DayWinStart,\n" +
				"	a.DayWinEnd,\n" +
				"	a.GroupId";
				
				
		System.out.println("sql " + sql);

        cx.log("Getting cust deliv: " + sql);
        try (PreparedStatement ps = con.prepareStatement(sql)){
            //ps.setString(1, RunId);
            try (ResultSet rs = ps.executeQuery()){
                while (rs.next()){
                    
                    FZCustDelivery cd = new FZCustDelivery();
                    int i=1;
                    
                    cd.custID = FZVrpUtil.getRsString(rs, i++, "");
                    cd.DONum = FZVrpUtil.getRsString(rs, i++, "");
                    
                    cd.lonStr = FZVrpUtil.getRsString(rs, i++, "0");
                    cd.lon = forceGetDouble(cd.lonStr
                            , "Longitude error cust " + cd.custID);

                    cd.latStr = FZVrpUtil.getRsString(rs, i++, "0");
                    cd.lat = forceGetDouble(cd.latStr
                            , "Latitude error cust " + cd.custID);
                    
                    cd.priority = FZVrpUtil.getRsInt(rs, i++
                            , cx.params.getInt("DefaultCustPriority"));
                    
                    cd.serviceTime = FZVrpUtil.getRsInt(rs, i++
                            , cx.params.getInt("DefaultCustServiceTime"));                    
					
                    cd.timeWindowStart = FZVrpUtil.getRsString(rs, i++, "0");//FZVrpUtil.getRsString(rs, i++
                            //, cx.params.get("DefaultCustStartTime"));					
                    cd.timeWindowEnd = FZVrpUtil.getRsString(rs, i++, "0");//FZVrpUtil.getRsString(rs, i++
                            //, cx.params.get("DefaultCustEndTime"));
                    
                    String vtl = FZVrpUtil.getRsString(rs, i++ 
                            , cx.params.get("DefaultCustVehicleTypes")); // vehicle type list
                    
                    cd.totalKg = FZVrpUtil.getRsString(rs, i++, "");
					//System.out.println("cd.totalKg" + cd.totalKg);
                    cd.totalVolume = FZVrpUtil.getRsString(rs, i++, "");
                    if (cx.params.get("CapacityInWeightOrVolume")
                            .equals("Volume")){
                        cd.totalCapacity = forceGetDouble(cd.totalVolume
                                , "Volume error cust " + cd.custID);
                    }
                    else {
                        cd.totalCapacity = forceGetDouble(cd.totalKg
                                , "Weight error cust " + cd.custID);
                    }
                    
                    String[] vts = vtl.split("\\|"); // vehicle types
                    for (String vt : vts){
                        cd.agentTypes.add(vt);
                    }
					//System.out.println("window open " + cd.custID + " : " + cd.timeWindowStart + "|" + cd.timeWindowEnd + "&" + cx.timeDistSource);
                    cds.add(cd);
                }
            }
        }
        cx.log("Cust deliv count: " + cds.size());
        return cds;
    }
/*
    private static void prepareCustTable(String branchCode, Connection con) 
        throws Exception {
        String sql = "EXEC bosnet1.dbo.GetCustLongLat ?";
        try (PreparedStatement ps = con.prepareStatement(sql)){
            ps.setEscapeProcessing(true);
            ps.setQueryTimeout(15);
            ps.setString(1, branchCode);
            ps.execute();
        }
    }
*/
    private static double forceGetDouble(String s, String errMsg) 
    throws Exception {
        try {
            double d = Double.parseDouble(s);
            return d;
        }
        catch(Exception e){
            throw new Exception(errMsg); 
        }
    }

    private List<FZDeliveryAgent> readDeliveryAgents(String RunId, String branchCode, String DelivDate,
             String shift, Connection con, FZAlgoContext cx) 
        throws Exception {
        
//VehicleID	MaxKG	VehicleCateg	MinStartTime	MaxEndTime	StartLon	StartLat	EndLon	EndLat	MaxCubication
        List<FZDeliveryAgent> das = new ArrayList<FZDeliveryAgent>();
        
        String sql = 
				"select\n" +
                "	a.vehicle_code,\n" +
                "	a.weight,\n" +
                "	a.volume,\n" +
                "	a.vehicle_type,\n" +
                "	a.branch,\n" +
                "	a.startLon,\n" +
                "	a.startLat,\n" +
                "	a.endLon,\n" +
                "	a.endLat,\n" +
                "	a.startTime,\n" +
                "	a.endTime,\n" +
                "	a.source1,\n" +
                "	a.fixedCost,\n" +    // TODO: alter table
                "	a.costPerM,\n" +
                "	a.costPerServiceMin,\n" +
                "	a.costPerTravelMin\n" +
                " from\n" +
                "	bosnet1.dbo.TMS_PreRouteVehicle a\n" +
                " where\n" +
                "	a.RunId = '"+RunId+"'\n" +
                "	and a.branch = '"+branchCode+"'\n" +
                "	and a.isActive = '1'";

        cx.log("Getting deliv agents: " + sql);

        try (PreparedStatement ps = con.prepareStatement(sql)){
            try (ResultSet rs = ps.executeQuery()){
                while (rs.next()){
                    FZDeliveryAgent da = new FZDeliveryAgent();
                    
                    int i = 1;
                    da.agentID = FZVrpUtil.getRsString(rs, i++, "");
                    da.maxKg = FZVrpUtil.getRsDouble(rs, i++, 0)
                            * cx.params.getDouble("MaxLoadFactor");
                    da.maxVolume = FZVrpUtil.getRsDouble(rs, i++, 0)
                            * cx.params.getDouble("MaxLoadFactor");
                    da.agentType = FZVrpUtil.getRsString(rs, i++, "");
                    da.branchCode = FZVrpUtil.getRsString(rs, i++, "");
                    da.startLon = FZVrpUtil.getRsDouble(rs, i++, 0);
                    da.startLat = FZVrpUtil.getRsDouble(rs, i++, 0);
                    da.endLon = FZVrpUtil.getRsDouble(rs, i++, 0);
                    da.endLat = FZVrpUtil.getRsDouble(rs, i++, 0);
                    da.earliestDepartTime = FZVrpUtil.getRsString(rs, i++
                            , cx.params.get("DefaultVehicleStartTime"));
                    da.latestArrivalTime = FZVrpUtil.getRsString(rs, i++
                            , cx.params.get("DefaultVehicleEndTime"));
                    
                    if (cx.params.get("CapacityInWeightOrVolume")
                            .equals("Volume")){
                        da.maxCapacity = da.maxVolume;
                    }
                    else {
                        da.maxCapacity = da.maxKg;
                    }
                    
                    da.source = FZVrpUtil.getRsString(rs, i++, "");

                    da.fixedCost = FZVrpUtil.getRsDouble(rs, i++, 0);
                    da.costPerDist = FZVrpUtil.getRsDouble(rs, i++, 0);
                    da.costPerServiceTime = FZVrpUtil.getRsDouble(rs, i++, 0);
                    da.costPerTravelTime = FZVrpUtil.getRsDouble(rs, i++, 0);

                    das.add(da);
                }
            }
        }
        cx.log("Deliv agents count: " + das.size());
        return das;
    }

    public void getCostDist(FZAlgoContext cx
            , Connection con) throws Exception {

        // init output
        ArrayList<JSONObject> finalCostDists = new ArrayList<JSONObject>();

        // get depo lon lat
        FZDeliveryAgent v = cx.deliveryAgents.get(0);
        String depoLon = String.valueOf(v.startLon);
        String depoLat = String.valueOf(v.startLat);

        if (cx.timeDistSource.startsWith("G")){
            cx.log("Use google");
            calcCostDistByGoogle(finalCostDists, cx, depoLon, depoLat, con);
        }
        else {
            cx.log("Use manhattan");
            calcCostDistByManhattan(finalCostDists, cx, depoLon, depoLat);
        }
        cx.costDists = finalCostDists;
    }

    private void calcCostDistByManhattan(ArrayList<JSONObject> finalCostDists
            , FZAlgoContext cx, String depoLon, String depoLat) 
            throws Exception {

        // for each cust1 
        for (FZCustDelivery cd1 : cx.custDeliveries){
            
            // calcManhattan from cust1 to depo
            calcManhattan(
                cd1.lonStr, cd1.latStr
                , depoLon, depoLat  
                , getCustIdDo(cd1), "DEPO_" + cx.branchCode
                , cx, finalCostDists
            );

            // calcManhattan from depo to cust1
            calcManhattan(
                depoLon, depoLat  
                , cd1.lonStr, cd1.latStr
                , "DEPO_" + cx.branchCode, getCustIdDo(cd1)
                , cx, finalCostDists
            );

            // for ceah cust2
            for (FZCustDelivery cd2 : cx.custDeliveries){

                // if not same cust1 and 2
                if (!cd1.custID.equals(cd2.custID)){

                    // calcManhattan from cust1 to cust2
                    calcManhattan(
                        cd1.lonStr, cd1.latStr
                        , cd2.lonStr, cd2.latStr
                        , getCustIdDo(cd1), getCustIdDo(cd2)  
                        , cx, finalCostDists
                    );
                }
            }
        }            
    }

    private void calcManhattan(
        String lon1, String lat1
        , String lon2, String lat2
        , String from1, String to1
        , FZAlgoContext cx
        , ArrayList<JSONObject> finalCostDists
    ) throws Exception {

            double x1 = Double.parseDouble(lon1);
            double y1 = Double.parseDouble(lat1);
            double x2 = Double.parseDouble(lon2);
            double y2 = Double.parseDouble(lat2);


            double distMtr = 
                    Math.abs(FZUtil.calcMeterDist(x1, y1, x2, y1))
                    + Math.abs(FZUtil.calcMeterDist(x2, y1, x2, y2))
                    ;
            
            double durMin = 
                    ((distMtr /1000) / cx.params.getDouble("SpeedKmPHour")) 
                    * 60;
            durMin = durMin * cx.params.getDouble("TrafficFactor");
            
            JSONObject custCostDist = new JSONObject();
            custCostDist.put("lon1", lon1);
            custCostDist.put("lat1", lat1);
            custCostDist.put("lon2", lon2);
            custCostDist.put("lat2", lat2);
            custCostDist.put("dist", distMtr);
            custCostDist.put("dur", durMin);
            custCostDist.put("from", from1);
            custCostDist.put("to", to1);
            finalCostDists.add(custCostDist);
    }

    private void calcCostDistByGoogle(ArrayList<JSONObject> finalCostDists
            , FZAlgoContext cx, String depoLon, String depoLat
            , Connection con
    ) throws Exception {

        // for each custDeliv (origin)
        for (FZCustDelivery cd1 : cx.custDeliveries){

            cx.log("Get CostDists of : " + cd1.custID
                + "; lat lon = " + cd1.latStr + ", " + cd1.lonStr
            );

            // try get costDist from db for this custDeliv
            // all from cd1
            // or from depo to cd1
            String sql = "select lon1,lat1,lon2,lat2,dist,dur "
                + " from bosnet1.dbo.TMS_CostDist "
                + " where "
                + "(lon1 = '" + cd1.lon + "'"
                + " and lat1 = '" + cd1.lat + "')"
                + " or "
                + "(lon1 = '" + depoLon + "'"
                + " and lat1 = '" + depoLat + "'"
                + " and lon2 = '" + cd1.lon + "'"
                + " and lat2 = '" + cd1.lat + "')"
                ;

            cx.log("Get dbCostDists: " + sql);

            ArrayList<JSONObject> dbCostDists = new ArrayList<JSONObject>();
            try (PreparedStatement ps = con.prepareStatement(sql);
                ResultSet rs = ps.executeQuery()){

                // keep costDist in list
                while (rs.next()){

                    JSONObject dbCostDist = new JSONObject();
                    dbCostDist.put("lon1", FZUtil.getRsString(rs, 1, "0"));
                    dbCostDist.put("lat1", FZUtil.getRsString(rs, 2, "0"));
                    dbCostDist.put("lon2", FZUtil.getRsString(rs, 3, "0"));
                    dbCostDist.put("lat2", FZUtil.getRsString(rs, 4, "0"));
                    dbCostDist.put("dist", FZUtil.getRsDouble(rs, 5, 0));
                    dbCostDist.put("dur", FZUtil.getRsDouble(rs, 6, 0));
                    dbCostDists.add(dbCostDist);
                }
                cx.log("dbCostDists size = " + dbCostDists.size());
            }

            // get dist and dur of each destinations
            // for each custDeliv (destination)
            ArrayList<JSONObject> notInDbCostDists = new ArrayList<JSONObject>(); 

            // find cust1 to depo
            findCostDist(
                cd1.lonStr, cd1.latStr
                , depoLon, depoLat
                , getCustIdDo(cd1), "DEPO_" + cx.branchCode
                , dbCostDists, notInDbCostDists, finalCostDists
                );

            for (FZCustDelivery cd2 : cx.custDeliveries){

                // if not itself
                if (cd1.custID != cd2.custID){

                    // find in costDist from loaded db record
                    findCostDist(
                        cd1.lonStr, cd1.latStr
                        , cd2.lonStr, cd2.latStr
                        , getCustIdDo(cd1), getCustIdDo(cd2)
                        , dbCostDists, notInDbCostDists, finalCostDists
                        );

                }
            }
            cx.log("notInDbCostDists size = " + notInDbCostDists.size());

            // if any to query google
            if (notInDbCostDists.size() > 0){

                // query google, from cust1 to all other cust, and depo
                queryGoogle(finalCostDists, notInDbCostDists
                    , cd1.lonStr, cd1.latStr, cx, con);

            }
            // get from depo to cust1

			// reset notInDbCostDists
			notInDbCostDists.clear();

			// find from depo to cust1
			findCostDist(
				depoLon, depoLat
				, cd1.lonStr, cd1.latStr
				, "DEPO_" + cx.branchCode, getCustIdDo(cd1)
				, dbCostDists, notInDbCostDists, finalCostDists
				);
			if (notInDbCostDists.size() > 0){
				// query google specific from depo to cust
				queryGoogle(finalCostDists, notInDbCostDists
					, depoLon, depoLat, cx, con);
			}
        }
        cx.log("finalCostDists size = " + finalCostDists.size());
    }

    private void findCostDist(
        String lon1, String lat1
        , String lon2, String lat2
        , String from1, String to1
        , ArrayList<JSONObject> dbCostDists
        , ArrayList<JSONObject> notInDbCostDists
        , ArrayList<JSONObject> finalCostDists
        ) throws Exception {

        JSONObject foundDbCostDist = null;
        for (JSONObject custCostDist : dbCostDists){

            // if costDist found
            if (
                (custCostDist.getString("lon1").equals(lon1))
                && (custCostDist.getString("lat1").equals(lat1))
                && (custCostDist.getString("lon2").equals(lon2))
                && (custCostDist.getString("lat2").equals(lat2))
            ){

                // keep & break
                foundDbCostDist = custCostDist;
                break;
            }

        }
        // if not found
        if (foundDbCostDist == null){

            // add to list to query to google
            JSONObject notInDbCostDist = new JSONObject();
            notInDbCostDist.put("lon1", lon1);
            notInDbCostDist.put("lat1", lat1);
            notInDbCostDist.put("lon2", lon2);
            notInDbCostDist.put("lat2", lat2);
            notInDbCostDist.put("from", from1);
            notInDbCostDist.put("to", to1);
            notInDbCostDists.add(notInDbCostDist);

        } else {
            // add to output list
            JSONObject custCostDist = new JSONObject();
            custCostDist.put("lon1", foundDbCostDist.getString("lon1"));
            custCostDist.put("lat1", foundDbCostDist.getString("lat1"));
            custCostDist.put("lon2", foundDbCostDist.getString("lon2"));
            custCostDist.put("lat2", foundDbCostDist.getString("lat2"));
            custCostDist.put("dist", foundDbCostDist.getDouble("dist"));
            custCostDist.put("dur", foundDbCostDist.getDouble("dur"));
            custCostDist.put("from", from1);
            custCostDist.put("to", to1);
            finalCostDists.add(custCostDist);
        }

    }

    private void queryGoogle(
            ArrayList<JSONObject> finalCostDists
            ,  ArrayList<JSONObject> notInDbCostDists
            , String origLon, String origLat
            , FZAlgoContext cx
            , Connection con
            ) throws Exception {

            // init
            ArrayList<JSONObject> destCostDists = new ArrayList<JSONObject>();
            //int maxDestInAPI = 25;

            // for each dest
            for (JSONObject notInDbCostDist : notInDbCostDists){

                // if destList > maxInAPI
                if (destCostDists.size() == maxDestInAPI){

                    // load from API
                    loadFromAPI(finalCostDists, destCostDists
                        , origLon, origLat, cx, con);

                    // init new destList
                    destCostDists.clear();
                }
				// add to destList
				destCostDists.add(notInDbCostDist);
            }

            // if destList not empty
            if (destCostDists.size() > 0){

                // load from API
                loadFromAPI(finalCostDists, destCostDists
                    , origLon, origLat, cx, con);

            }
    }

    // load from API
    private void loadFromAPI(
        ArrayList<JSONObject> finalCostDists
        , ArrayList<JSONObject> destCostDists
        , String origLon, String origLat
        , FZAlgoContext cx
        , Connection con
        ) throws Exception {

        // create dest list
        String destList = "";
        for (JSONObject destCostDist : destCostDists){
            if (destList.length() > 0) destList += "|";
            destList += 
                destCostDist.getString("lat2")
                + ","
                + destCostDist.getString("lon2");
        }

        // call API
        // prepare google API call
        int maxRetry = 100;
        String urlString =
            "https://maps.googleapis.com/maps/api/distancematrix/json"
                + "?origins=" + origLat + "," + origLon
                + "&destinations=" + destList
                + "&departure_time=now"
                + "&traffic_model=best_guess"
                ;
        String key = "AIzaSyBOsad8CCGx7acE9H_c-27JVH-qqKzei20";
        //String clientID = "180317705838-9jb8pfq0l9qqr4n5crno2nule8uhnvp0.apps.googleusercontent.com";

        URL url = new URL(urlString + "&key=" + key);
        String finalURL = url.toString();
        URL obj = new URL(finalURL);
        cx.log(finalURL);
		System.out.println(maxDestInAPI + " "+ finalURL);
        // loop to call google API
        for (int retry=1; retry<=maxRetry; retry++){

            cx.log("Trial no " + retry);

            // call google API
            HttpURLConnection htCon = (HttpURLConnection) obj.openConnection();
            htCon.setRequestMethod("GET");
            htCon.setRequestProperty("User-Agent", "Mozilla/5.0");
            String resultJson = "";
            try (BufferedReader in = new BufferedReader(
                    new InputStreamReader(htCon.getInputStream()))){
                String inputLine;
                StringBuffer response = new StringBuffer();
                while ((inputLine = in.readLine()) != null) {
                        response.append(inputLine);
                }
                in.close();
                resultJson = response.toString();
            }
            cx.log(resultJson);

            // parse result
            // check google response status, if not ok go to loop
            JSONObject obj1 = new JSONObject(resultJson);
            String status = obj1.getString("status");
            if (!status.equals("OK")){
                continue;
            }

            // parse ok, get rows
            JSONArray arr = obj1.getJSONArray("rows");
            if (arr.length() >= 1) {

                // for each destinations
                JSONObject row = arr.getJSONObject(0);
                JSONArray elms = row.getJSONArray("elements");
                for (int i =0 ;i < destCostDists.size() ; i++){

                    JSONObject destCostDist = destCostDists.get(i);
                    JSONObject elm = elms.getJSONObject(i);

                    // get dur & dist
                    JSONObject durElm = elm.getJSONObject("duration");
                    String durVal = durElm.getString("value");

                    JSONObject distElm = elm.getJSONObject("distance");
                    String distVal = distElm.getString("value");

                    String durTrfVal = durVal;
                    if (elm.has("duration_in_traffic")){
                        JSONObject durTrfElm = elm.getJSONObject(
                                "duration_in_traffic");
                        durTrfVal = durTrfElm.getString("value");
                    }
                    else {
                        //System.out.println("");
                    }

                    // convert second to min
                    double durValDbl = Double.parseDouble(durVal) / 60;
                    
                    // add to list
                    JSONObject custCostDist = new JSONObject();
                    custCostDist.put("lon1", destCostDist.getString("lon1"));
                    custCostDist.put("lat1", destCostDist.getString("lat1"));
                    custCostDist.put("lon2", destCostDist.getString("lon2"));
                    custCostDist.put("lat2", destCostDist.getString("lat2"));
                    custCostDist.put("dist", distVal);
                    custCostDist.put("dur", durValDbl);
                    custCostDist.put("from", destCostDist.getString("from"));
                    custCostDist.put("to", destCostDist.getString("to"));
                    finalCostDists.add(custCostDist);

                    // save to db
                    String sql = "insert into bosnet1.dbo.TMS_CostDist"
                        + "(lon1, lat1, lon2, lat2, dist, dur, branch"
                        + ", from1, to1)"
                        + " values("
                        + "'" + custCostDist.getString("lon1") + "'"
                        + ",'" + custCostDist.getString("lat1") + "'"
                        + ",'" + custCostDist.getString("lon2") + "'"
                        + ",'" + custCostDist.getString("lat2") + "'"
                        + ",'" + custCostDist.getString("dist") + "'"
                        + ",'" + custCostDist.getString("dur") + "'"
                        + ",'" + cx.branchCode + "'"
                        + ",'" + custCostDist.getString("from") + "'"
                        + ",'" + custCostDist.getString("to") + "'"
                        + ")"
                        ;

                    cx.log("insert CostDist: " + sql);

                    try (PreparedStatement ps = con.prepareStatement(sql)){
                        ps.executeUpdate();
                    }

                }
            }
            else {
                throw new Exception("Error: " 
                        + "\n" + resultJson);
            }

            // quit retry loop
            break;

        }
    }
    private String getCustIdDo(FZCustDelivery cd){
        return cd.custID + "-" + cd.DONum;
    }
%>
<%=run(request, response, pageContext)%>